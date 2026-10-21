package docker

import (
	"archive/tar"
	"context"
	"encoding/base64"
	"encoding/json"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"sort"
	"strconv"
	"strings"
)

func workspacePath(p string) (string, error) {
	clean := path.Clean("/workspace/" + strings.TrimPrefix(p, "/"))
	if clean != "/workspace" && !strings.HasPrefix(clean, "/workspace/") {
		return "", errs.InvalidArgument("path is outside the workspace")
	}
	return clean, nil
}

// archive streams p as a tar. With folderOnly (a misnomer kept short: "files
// only"), a folder is refused before its contents are sent.
func (a *Adapter) archive(ctx context.Context, id, p string, folderOnly bool) (*http.Response, error) {
	cid, e := a.containerID(id)
	if e != nil {
		return nil, e
	}
	target, e := workspacePath(p)
	if e != nil {
		return nil, e
	}
	req, e := http.NewRequestWithContext(ctx, http.MethodGet, a.url("/containers/"+cid+"/archive?path="+url.QueryEscape(target)), nil)
	if e != nil {
		return nil, e
	}
	res, e := a.client.Do(req)
	if e != nil {
		return nil, e
	}
	if res.StatusCode >= 400 {
		res.Body.Close()
		return nil, errs.NotFound("workspace path")
	}
	if stat := res.Header.Get("X-Docker-Container-Path-Stat"); stat != "" {
		raw, e := base64.StdEncoding.DecodeString(stat)
		if e != nil {
			res.Body.Close()
			return nil, e
		}
		var s struct {
			LinkTarget string `json:"linkTarget"`
			Mode       uint32 `json:"mode"`
		}
		_ = json.Unmarshal(raw, &s)
		if folderOnly && s.Mode&uint32(os.ModeDir) != 0 {
			res.Body.Close()
			return nil, errs.NotFound("regular workspace file")
		}
		if s.LinkTarget != "" && (!strings.HasPrefix(path.Clean(s.LinkTarget), "/workspace/") && path.Clean(s.LinkTarget) != "/workspace") {
			res.Body.Close()
			return nil, errs.Permission("workspace symlink escapes its root")
		}
	}
	return res, nil
}
func (a *Adapter) ReadWorkspace(ctx context.Context, id, p string) ([]byte, error) {
	r, e := a.archive(ctx, id, p, true)
	if e != nil {
		return nil, e
	}
	defer r.Body.Close()
	reader := tar.NewReader(io.LimitReader(r.Body, 65<<20))
	for {
		h, e := reader.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			return nil, e
		}
		if h.Typeflag != tar.TypeReg {
			continue
		}
		if h.Size > 64<<20 {
			return nil, errs.InvalidArgument("file exceeds 64 MiB")
		}
		return io.ReadAll(reader)
	}
	return nil, errs.NotFound("regular workspace file")
}

// ListWorkspace (vmm.WorkspaceReader) lists one folder. It is never read
// as an archive (that sends everything under it, which for a project with
// its dependencies is far too much): a running computer lists it itself, a
// stopped one through a helper container on its volume.
func (a *Adapter) ListWorkspace(ctx context.Context, id, p string) ([]vmm.WorkspaceEntry, error) {
	target, e := workspacePath(p)
	if e != nil {
		return nil, e
	}
	const script = `cd "$1" 2>/dev/null || exit 3; find . -mindepth 1 -maxdepth 1 -printf '%y|%s|%f\0' 2>/dev/null`
	var out string
	if a.running(ctx, id) {
		got, err := a.Send(ctx, id, strings.Replace(script, `"$1"`, shellQuote(target), 1))
		if err != nil {
			return nil, err
		}
		code, rest, _ := strings.Cut(got, "\n")
		if code == "exit=3" {
			return nil, errs.NotFound("workspace folder")
		}
		if code != "exit=0" {
			return nil, errs.New(errs.CodeVMM, "list workspace: "+got)
		}
		out = rest
	} else {
		code, got, err := a.helperOutput(ctx, id, script, target)
		if code == 3 {
			return nil, errs.NotFound("workspace folder")
		}
		if err != nil {
			return nil, err
		}
		out = got
	}
	return parseListing(out)
}

// parseListing reads find's "type|size|name" records (NUL-separated).
func parseListing(out string) ([]vmm.WorkspaceEntry, error) {
	entries := []vmm.WorkspaceEntry{}
	for _, rec := range strings.Split(out, "\x00") {
		kind, rest, ok := strings.Cut(strings.TrimLeft(rec, "\n"), "|")
		if !ok {
			continue
		}
		size, name, ok := strings.Cut(rest, "|")
		if !ok || name == "" {
			continue
		}
		switch kind {
		case "d":
			entries = append(entries, vmm.WorkspaceEntry{Name: name, Type: "dir"})
		case "f":
			n, _ := strconv.ParseInt(size, 10, 64)
			entries = append(entries, vmm.WorkspaceEntry{Name: name, Type: "file", Size: n})
		}
		if len(entries) > 10000 {
			return nil, errs.InvalidArgument("directory contains too many entries")
		}
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name < entries[j].Name })
	return entries, nil
}

// running reports whether the computer's container runs now.
func (a *Adapter) running(ctx context.Context, id string) bool {
	cid, err := a.containerID(id)
	if err != nil {
		return false
	}
	b, err := a.do(ctx, http.MethodGet, "/containers/"+cid+"/json", nil)
	if err != nil {
		return false
	}
	var spec struct {
		State struct {
			Running bool `json:"Running"`
		} `json:"State"`
	}
	return json.Unmarshal(b, &spec) == nil && spec.State.Running
}

func shellQuote(v string) string { return "'" + strings.ReplaceAll(v, "'", `'\''`) + "'" }
