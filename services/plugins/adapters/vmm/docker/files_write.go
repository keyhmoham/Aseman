package docker

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// A project's files are on its workspace volume, so they can be changed while
// its computer is stopped: Docker's archive API puts files and folders into a
// stopped container's volume, and what it cannot do (delete, move) a helper
// container does, mounting the same volume for a moment. Neither starts the
// computer.

var (
	_ vmm.WorkspaceWriter    = (*Adapter)(nil)
	_ vmm.WorkspaceOrganizer = (*Adapter)(nil)
)

// helperTimeout bounds a helper container's work.
const helperTimeout = 2 * time.Minute

// WriteWorkspace (vmm.WorkspaceWriter): put a file into the project's files,
// creating its folders.
func (a *Adapter) WriteWorkspace(ctx context.Context, id, p string, data []byte) error {
	target, err := workspacePath(p)
	if err != nil {
		return err
	}
	if target == "/workspace" {
		return errs.InvalidArgument("a file path is required")
	}
	return a.putArchive(ctx, id, strings.TrimPrefix(target, "/workspace/"), data, false)
}

// MakeWorkspaceDir (vmm.WorkspaceOrganizer): make a folder and its parents.
func (a *Adapter) MakeWorkspaceDir(ctx context.Context, id, p string) error {
	target, err := workspacePath(p)
	if err != nil {
		return err
	}
	if target == "/workspace" {
		return nil
	}
	return a.putArchive(ctx, id, strings.TrimPrefix(target, "/workspace/"), nil, true)
}

// DeleteWorkspace (vmm.WorkspaceWriter): remove a file or folder.
func (a *Adapter) DeleteWorkspace(ctx context.Context, id, p string) error {
	target, err := workspacePath(p)
	if err != nil {
		return err
	}
	if target == "/workspace" {
		return errs.InvalidArgument("cannot delete the workspace root")
	}
	_, err = a.helper(ctx, id, `rm -rf -- "$1"`, target)
	return err
}

// MoveWorkspace (vmm.WorkspaceOrganizer): move or rename a file or folder.
func (a *Adapter) MoveWorkspace(ctx context.Context, id, from, to string) error {
	src, err := workspacePath(from)
	if err != nil {
		return err
	}
	dst, err := workspacePath(to)
	if err != nil {
		return err
	}
	if src == "/workspace" || dst == "/workspace" {
		return errs.InvalidArgument("cannot move the workspace root")
	}
	code, err := a.helper(ctx, id, `[ -e "$1" ] || exit 4; [ -e "$2" ] && exit 3; mkdir -p "$(dirname "$2")" && mv -- "$1" "$2"`, src, dst)
	switch {
	case code == 3:
		return vmm.ErrExists
	case code == 4:
		return errs.NotFound("workspace path")
	}
	return err
}

// putArchive writes one file (or, with dir, one folder) at rel under
// /workspace, with its parent folders, through Docker's archive API.
func (a *Adapter) putArchive(ctx context.Context, id, rel string, data []byte, dir bool) error {
	cid, err := a.containerID(id)
	if err != nil {
		return err
	}
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	now := time.Now()
	parts := strings.Split(rel, "/")
	for i := 1; i < len(parts); i++ {
		if err := tw.WriteHeader(&tar.Header{Typeflag: tar.TypeDir, Name: strings.Join(parts[:i], "/") + "/", Mode: 0o755, ModTime: now}); err != nil {
			return err
		}
	}
	if dir {
		err = tw.WriteHeader(&tar.Header{Typeflag: tar.TypeDir, Name: rel + "/", Mode: 0o755, ModTime: now})
	} else {
		err = tw.WriteHeader(&tar.Header{Typeflag: tar.TypeReg, Name: rel, Mode: 0o644, Size: int64(len(data)), ModTime: now})
		if err == nil {
			_, err = tw.Write(data)
		}
	}
	if err != nil {
		return err
	}
	if err := tw.Close(); err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, a.url("/containers/"+cid+"/archive?path="+url.QueryEscape("/workspace")), &buf)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-tar")
	res, err := a.client.Do(req)
	if err != nil {
		return errs.Wrap(errs.CodeVMM, err, "write workspace file")
	}
	defer res.Body.Close()
	if res.StatusCode >= 400 {
		var b bytes.Buffer
		_, _ = b.ReadFrom(res.Body)
		return errs.New(errs.CodeVMM, "write workspace file: "+strings.TrimSpace(b.String()))
	}
	return nil
}

// helper runs a short shell script, with args as $1…, in a throwaway
// container of the computer's image that mounts the computer's workspace
// volume (and nothing else: no network). It returns the script's exit code;
// an error when the code is not 0 or the container could not run.
func (a *Adapter) helper(ctx context.Context, id, script string, args ...string) (int, error) {
	cid, err := a.containerID(id)
	if err != nil {
		return -1, err
	}
	raw, err := a.do(ctx, http.MethodGet, "/containers/"+cid+"/json", nil)
	if err != nil {
		return -1, err
	}
	var info struct {
		Config struct {
			Image string `json:"Image"`
		} `json:"Config"`
		Mounts []struct {
			Type        string `json:"Type"`
			Name        string `json:"Name"`
			Destination string `json:"Destination"`
		} `json:"Mounts"`
	}
	if err := json.Unmarshal(raw, &info); err != nil {
		return -1, err
	}
	volume := ""
	for _, m := range info.Mounts {
		if m.Type == "volume" && m.Destination == "/workspace" {
			volume = m.Name
		}
	}
	if volume == "" || info.Config.Image == "" {
		// Its files live only inside the container: change them through it.
		return -1, vmm.ErrUnsupported
	}
	ctx, cancel := context.WithTimeout(ctx, helperTimeout)
	defer cancel()
	create := map[string]any{
		"Image":           info.Config.Image,
		"Entrypoint":      []string{"/bin/sh", "-c"},
		"Cmd":             append([]string{script, "sh"}, args...),
		"User":            "0",
		"NetworkDisabled": true,
		"Labels":          map[string]string{"tradera.files_helper_of": id},
		"HostConfig": map[string]any{
			"Mounts":      []map[string]any{{"Type": "volume", "Source": volume, "Target": "/workspace"}},
			"NetworkMode": "none",
			"AutoRemove":  false,
		},
	}
	out, err := a.do(ctx, http.MethodPost, "/containers/create", create)
	if err != nil {
		return -1, errs.Wrap(errs.CodeVMM, err, "files helper")
	}
	var created struct {
		ID string `json:"Id"`
	}
	if err := json.Unmarshal(out, &created); err != nil || created.ID == "" {
		return -1, errs.New(errs.CodeVMM, "files helper was not created")
	}
	defer func() { _ = a.remove(context.WithoutCancel(ctx), created.ID, true) }()
	if _, err := a.do(ctx, http.MethodPost, "/containers/"+created.ID+"/start", nil); err != nil {
		return -1, errs.Wrap(errs.CodeVMM, err, "files helper")
	}
	waited, err := a.do(ctx, http.MethodPost, "/containers/"+created.ID+"/wait", nil)
	if err != nil {
		return -1, errs.Wrap(errs.CodeVMM, err, "files helper")
	}
	var result struct {
		StatusCode int `json:"StatusCode"`
	}
	if err := json.Unmarshal(waited, &result); err != nil {
		return -1, err
	}
	if result.StatusCode != 0 {
		return result.StatusCode, errs.New(errs.CodeVMM, fmt.Sprintf("files helper exited %d", result.StatusCode))
	}
	return 0, nil
}
