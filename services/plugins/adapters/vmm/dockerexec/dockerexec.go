// Package dockerexec provides standalone docker exec helpers shared by VMM
// adapters that host containers (the standalone docker adapter and the nomad
// adapter's docker driver). Commands are executed inside a container via the
// Docker Engine HTTP API over its unix socket or a TCP endpoint.
package dockerexec

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/tradera/tradera/pkg/errs"
)

// DefaultHost is the docker daemon unix socket used when none is configured.
const DefaultHost = "unix:///var/run/docker.sock"

// Client wraps a docker daemon endpoint.
type Client struct {
	host    string
	baseURL string
	http    *http.Client
}

// New returns a docker client for the given host ("unix://..." or an http URL).
func New(host string) *Client {
	if host == "" {
		host = DefaultHost
	}
	c := &Client{host: host}
	if strings.HasPrefix(host, "unix://") {
		sock := strings.TrimPrefix(host, "unix://")
		c.baseURL = "http://docker"
		c.http = &http.Client{
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					return (&net.Dialer{}).DialContext(ctx, "unix", sock)
				},
			},
		}
	} else {
		c.baseURL = strings.TrimRight(host, "/")
		c.http = &http.Client{Timeout: 60 * time.Second}
	}
	return c
}

// Exec runs a shell command inside a container and returns its output with the
// exit code, mirroring the standalone docker adapter's behaviour.
func (c *Client) Exec(ctx context.Context, containerID, command string) (string, error) {
	if command == "" {
		command = "/bin/sh"
	}
	// Bound every sandbox command so an exec stream can never block forever.
	// Long-running processes (dev servers, tunnels, watchers) would otherwise
	// hold the docker exec open indefinitely and hang the calling agent/workflow.
	// `timeout` sends SIGTERM then SIGKILL after a grace period; exit code 124
	// signals a timed-out command. Launch long-lived daemons with "&" instead.
	const sandboxExecTimeout = "300" // seconds
	execCmd := []string{"timeout", "-k", "15s", sandboxExecTimeout, "/bin/sh", "-c", command}
	create := map[string]any{
		"AttachStdout": true,
		"AttachStderr": true,
		"AttachStdin":  false,
		"Tty":          false,
		"Cmd":          execCmd,
	}
	cb, err := c.do(ctx, http.MethodPost, "/containers/"+containerID+"/exec", create)
	if err != nil {
		return "", errs.Wrap(errs.CodeVMM, err, "create exec")
	}
	var exec struct {
		ID string `json:"Id"`
	}
	if err := json.Unmarshal(cb, &exec); err != nil || exec.ID == "" {
		return "", errs.New(errs.CodeVMM, "docker exec: bad create response")
	}
	raw, err := c.execStream(ctx, "/exec/"+exec.ID+"/start", map[string]any{"Detach": false, "Tty": false})
	if err != nil {
		return "", err
	}
	jb, err := c.do(ctx, http.MethodGet, "/exec/"+exec.ID+"/json", nil)
	code := "0"
	if err == nil {
		var info struct {
			ExitCode int `json:"ExitCode"`
		}
		if json.Unmarshal(jb, &info) == nil {
			code = fmt.Sprintf("%d", info.ExitCode)
		}
	}
	text := demuxStream(raw)
	if text == "" {
		text = "(no output)"
	}
	return fmt.Sprintf("exit=%s\n%s", code, text), nil
}

// FindContainerByLabel returns the id of the first container matching a docker
// label filter (e.g. "com.hashicorp.nomad.allocation_id=<id>").
func (c *Client) FindContainerByLabel(ctx context.Context, label string) (string, error) {
	b, err := c.do(ctx, http.MethodGet, "/containers/json?all=true&filters="+
		url.QueryEscape(fmt.Sprintf(`{"label":["%s"]}`, label)), nil)
	if err != nil {
		return "", errs.Wrap(errs.CodeVMM, err, "list containers by label")
	}
	var list []struct {
		ID string `json:"Id"`
	}
	if err := json.Unmarshal(b, &list); err != nil {
		return "", errs.Wrap(errs.CodeVMM, err, "decode container list")
	}
	if len(list) == 0 {
		return "", errs.NotFound("container with label " + label)
	}
	return list[0].ID, nil
}

func (c *Client) do(ctx context.Context, method, path string, body any) ([]byte, error) {
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.baseURL+path, r)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "docker "+method+" "+path)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		return nil, errs.New(errs.CodeVMM, fmt.Sprintf("docker %s %s: %s", method, path, string(b)))
	}
	return b, nil
}

func (c *Client) execStream(ctx context.Context, path string, body any) ([]byte, error) {
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, r)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "docker stream "+path)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		return nil, errs.New(errs.CodeVMM, fmt.Sprintf("docker %s: %s", path, string(b)))
	}
	return b, nil
}

func demuxStream(raw []byte) string {
	var sb strings.Builder
	i := 0
	for i+8 <= len(raw) {
		streamType := raw[i]
		frameLen := int(raw[i+4])<<24 | int(raw[i+5])<<16 | int(raw[i+6])<<8 | int(raw[i+7])
		i += 8
		if i+frameLen > len(raw) {
			frameLen = len(raw) - i
		}
		if frameLen < 0 {
			break
		}
		if streamType == 1 || streamType == 2 {
			sb.Write(raw[i : i+frameLen])
		}
		i += frameLen
	}
	if sb.Len() == 0 {
		return string(raw)
	}
	return strings.TrimSpace(sb.String())
}
