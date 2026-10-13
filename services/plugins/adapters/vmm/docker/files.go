package docker

import (
	"archive/tar"
	"context"
	"encoding/base64"
	"encoding/json"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
	"io"
	"net/http"
	"net/url"
	"path"
	"sort"
	"strings"
)

func workspacePath(p string) (string, error) {
	clean := path.Clean("/workspace/" + strings.TrimPrefix(p, "/"))
	if clean != "/workspace" && !strings.HasPrefix(clean, "/workspace/") {
		return "", errs.InvalidArgument("path is outside the workspace")
	}
	return clean, nil
}
func (a *Adapter) archive(ctx context.Context, id, p string) (*http.Response, error) {
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
		}
		_ = json.Unmarshal(raw, &s)
		if s.LinkTarget != "" && (!strings.HasPrefix(path.Clean(s.LinkTarget), "/workspace/") && path.Clean(s.LinkTarget) != "/workspace") {
			res.Body.Close()
			return nil, errs.Permission("workspace symlink escapes its root")
		}
	}
	return res, nil
}
func (a *Adapter) ReadWorkspace(ctx context.Context, id, p string) ([]byte, error) {
	r, e := a.archive(ctx, id, p)
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
func (a *Adapter) ListWorkspace(ctx context.Context, id, p string) ([]vmm.WorkspaceEntry, error) {
	r, e := a.archive(ctx, id, p)
	if e != nil {
		return nil, e
	}
	defer r.Body.Close()
	reader := tar.NewReader(io.LimitReader(r.Body, 65<<20))
	entries := map[string]vmm.WorkspaceEntry{}
	root := ""
	for {
		h, e := reader.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			return nil, e
		}
		name := path.Clean(h.Name)
		if root == "" {
			root = strings.Split(name, "/")[0]
		}
		rest := strings.TrimPrefix(name, root+"/")
		if rest == root || rest == "." || rest == "" {
			continue
		}
		parts := strings.Split(rest, "/")
		entry := vmm.WorkspaceEntry{Name: parts[0], Type: "file", Size: h.Size}
		if len(parts) > 1 || h.Typeflag == tar.TypeDir {
			entry.Type = "dir"
			entry.Size = 0
		}
		if h.Typeflag == tar.TypeSymlink || h.Typeflag == tar.TypeLink {
			continue
		}
		entries[entry.Name] = entry
		if len(entries) > 10000 {
			return nil, errs.InvalidArgument("directory contains too many entries")
		}
	}
	out := []vmm.WorkspaceEntry{}
	for _, e := range entries {
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}
