package dockerexec

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// Attach starts an interactive process inside a running container and returns
// its stdio: writes go to the process' stdin, reads return its stdout, and
// stderr frames are copied to [stderr] (discarded when nil). The returned
// stream outlives ctx, which only bounds the attach handshake.
func (c *Client) Attach(ctx context.Context, containerID string, spec vmm.ExecSpec, stderr io.Writer) (vmm.ExecStream, error) {
	if len(spec.Cmd) == 0 {
		return nil, errs.InvalidArgument("attach requires a command")
	}
	create := map[string]any{
		"AttachStdin":  true,
		"AttachStdout": true,
		"AttachStderr": true,
		"Tty":          false,
		"Cmd":          spec.Cmd,
		"Env":          envList(spec.Env),
	}
	if spec.WorkDir != "" {
		create["WorkingDir"] = spec.WorkDir
	}
	if spec.User != "" {
		create["User"] = spec.User
	}
	cb, err := c.do(ctx, http.MethodPost, "/containers/"+containerID+"/exec", create)
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "create interactive exec")
	}
	var exec struct {
		ID string `json:"Id"`
	}
	if err := json.Unmarshal(cb, &exec); err != nil || exec.ID == "" {
		return nil, errs.New(errs.CodeVMM, "docker exec: bad create response")
	}
	conn, err := c.dial(ctx)
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "dial docker for attach")
	}
	body, _ := json.Marshal(map[string]any{"Detach": false, "Tty": false})
	req, err := http.NewRequest(http.MethodPost, "http://docker/exec/"+exec.ID+"/start", bytes.NewReader(body))
	if err != nil {
		conn.Close()
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "tcp")
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}
	if err := req.Write(conn); err != nil {
		conn.Close()
		return nil, errs.Wrap(errs.CodeVMM, err, "start interactive exec")
	}
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, req)
	if err != nil {
		conn.Close()
		return nil, errs.Wrap(errs.CodeVMM, err, "read attach response")
	}
	if resp.StatusCode != http.StatusSwitchingProtocols && resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		conn.Close()
		return nil, errs.New(errs.CodeVMM, fmt.Sprintf("attach exec: %s: %s", resp.Status, strings.TrimSpace(string(msg))))
	}
	_ = conn.SetDeadline(time.Time{})
	if stderr == nil {
		stderr = io.Discard
	}
	return &stream{conn: conn, br: br, stderr: stderr}, nil
}

// dial opens a raw connection to the docker daemon for a hijacked stream.
func (c *Client) dial(ctx context.Context) (net.Conn, error) {
	d := &net.Dialer{}
	if strings.HasPrefix(c.host, "unix://") {
		return d.DialContext(ctx, "unix", strings.TrimPrefix(c.host, "unix://"))
	}
	u, err := url.Parse(c.baseURL)
	if err != nil {
		return nil, err
	}
	host := u.Host
	if u.Port() == "" {
		host = net.JoinHostPort(u.Hostname(), "2375")
	}
	return d.DialContext(ctx, "tcp", host)
}

// stream demultiplexes docker's attach framing (8-byte headers, stream type 1
// stdout / 2 stderr) into a plain stdout reader.
type stream struct {
	conn      net.Conn
	br        *bufio.Reader
	stderr    io.Writer
	remaining int
	readMu    sync.Mutex
	writeMu   sync.Mutex
}

func (s *stream) Read(p []byte) (int, error) {
	s.readMu.Lock()
	defer s.readMu.Unlock()
	for s.remaining == 0 {
		var hdr [8]byte
		if _, err := io.ReadFull(s.br, hdr[:]); err != nil {
			return 0, err
		}
		size := int(binary.BigEndian.Uint32(hdr[4:]))
		if hdr[0] == 2 {
			if _, err := io.CopyN(s.stderr, s.br, int64(size)); err != nil {
				return 0, err
			}
			continue
		}
		s.remaining = size
	}
	if len(p) > s.remaining {
		p = p[:s.remaining]
	}
	n, err := s.br.Read(p)
	s.remaining -= n
	return n, err
}

func (s *stream) Write(p []byte) (int, error) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	return s.conn.Write(p)
}

func (s *stream) Close() error { return s.conn.Close() }

func envList(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k, v := range m {
		out = append(out, k+"="+v)
	}
	sort.Strings(out)
	return out
}
