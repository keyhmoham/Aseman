package modal

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"io"
	"net/http"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"

	modal "github.com/modal-labs/modal-client/go"
	pb "github.com/modal-labs/modal-client/go/proto/modal_proto"
)

// A project's files are on its workspace volume, so they can be read and written
// while its computer is stopped, without starting a sandbox. Modal's Go client
// has no file calls for volumes, but its public protobuf package has the RPCs,
// which are used here on the client's own authenticated connection.
//
// A running computer sees the volume only after a reload, and its own writes
// reach the volume only when committed, so while it runs its files are read and
// written through the computer itself (exec). The volume API serves the rest.
const (
	maxReadBytes  = 32 << 20
	maxWriteBytes = 3 << 20 // larger offline writes need a blob upload; they wake the computer instead
)

var _ vmm.WorkspaceReader = (*Adapter)(nil)
var _ vmm.WorkspaceWriter = (*Adapter)(nil)
var _ vmm.WorkspaceOrganizer = (*Adapter)(nil)

// ListWorkspace (vmm.WorkspaceReader): list a directory of the project's files.
func (a *Adapter) ListWorkspace(ctx context.Context, id, p string) ([]vmm.WorkspaceEntry, error) {
	dir, err := workspaceDir(p)
	if err != nil {
		return nil, err
	}
	if live := a.liveSandbox(id); live != nil {
		// A computer Modal ended by itself still looks live here until it is
		// next used: its files are on the volume, so read them from there.
		if entries, err := a.listViaExec(ctx, live, dir); err == nil || a.Alive(ctx, id) {
			return entries, err
		}
	}
	api, vol, err := a.volume(ctx, id)
	if err != nil {
		return nil, err
	}
	rel := strings.TrimPrefix(strings.TrimPrefix(dir, "/workspace"), "/")
	stream, err := api.VolumeListFiles(ctx, pb.VolumeListFilesRequest_builder{VolumeId: vol, Path: rel}.Build())
	if err != nil {
		return nil, listError(err)
	}
	seen := map[string]vmm.WorkspaceEntry{}
	for {
		resp, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, listError(err)
		}
		for _, e := range resp.GetEntries() {
			name := path.Base(e.GetPath())
			if name == "." || name == "/" || name == "" || (rel != "" && strings.Trim(e.GetPath(), "/") == strings.Trim(rel, "/")) {
				continue
			}
			entry := vmm.WorkspaceEntry{Name: name, Type: "file", Size: int64(e.GetSize())}
			if e.GetType() == pb.FileEntry_DIRECTORY {
				entry.Type, entry.Size = "dir", 0
			}
			seen[name] = entry
		}
	}
	out := make([]vmm.WorkspaceEntry, 0, len(seen))
	for _, e := range seen {
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// listError tells a folder that does not exist (nothing to wake a computer
// for) from the provider failing.
func listError(err error) error {
	if status.Code(err) == codes.NotFound {
		return errs.NotFound("workspace folder")
	}
	return errs.Wrap(errs.CodeVMM, err, "list workspace")
}

// ReadWorkspace (vmm.WorkspaceReader): read one of the project's files.
func (a *Adapter) ReadWorkspace(ctx context.Context, id, p string) ([]byte, error) {
	file, err := workspaceDir(p)
	if err != nil {
		return nil, err
	}
	if live := a.liveSandbox(id); live != nil {
		if data, err := a.readViaExec(ctx, live, file); err == nil || a.Alive(ctx, id) {
			return data, err
		}
	}
	api, vol, err := a.volume(ctx, id)
	if err != nil {
		return nil, err
	}
	rel := strings.TrimPrefix(strings.TrimPrefix(file, "/workspace"), "/")
	resp, err := api.VolumeGetFile(ctx, pb.VolumeGetFileRequest_builder{VolumeId: vol, Path: rel}.Build())
	if err != nil {
		// Only a file the volume says is absent is "not found": a provider
		// failure must not read as an empty project.
		if status.Code(err) == codes.NotFound {
			return nil, errs.NotFound("workspace file")
		}
		return nil, errs.Wrap(errs.CodeVMM, err, "read workspace file")
	}
	if resp.GetSize() > maxReadBytes {
		return nil, errs.InvalidArgument("file exceeds 32 MiB")
	}
	if blob := resp.GetDataBlobId(); blob != "" {
		got, err := api.BlobGet(ctx, pb.BlobGetRequest_builder{BlobId: blob}.Build())
		if err != nil {
			return nil, errs.Wrap(errs.CodeVMM, err, "read workspace file")
		}
		return download(ctx, got.GetDownloadUrl())
	}
	return resp.GetData(), nil
}

// WriteWorkspace (vmm.WorkspaceWriter): put a file into a stopped project's
// files. A running computer writes through itself. Files above maxWriteBytes are
// refused here (ErrTooLarge) so the caller can start the computer instead.
func (a *Adapter) WriteWorkspace(ctx context.Context, id, p string, data []byte) error {
	file, err := workspaceDir(p)
	if err != nil {
		return err
	}
	if file == "/workspace" {
		return errs.InvalidArgument("a file path is required")
	}
	if live := a.liveSandbox(id); live != nil {
		return a.writeViaExec(ctx, live, file, data)
	}
	if len(data) > maxWriteBytes {
		return vmm.ErrTooLarge
	}
	api, vol, err := a.volume(ctx, id)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(data)
	hexSum := hex.EncodeToString(sum[:])
	if _, err := api.MountPutFile(ctx, pb.MountPutFileRequest_builder{Sha256Hex: hexSum, Data: data}.Build()); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "write workspace file")
	}
	size, mode := uint64(len(data)), uint32(0o644)
	_, err = api.VolumePutFiles(ctx, pb.VolumePutFilesRequest_builder{
		VolumeId: vol,
		Files:    []*pb.MountFile{pb.MountFile_builder{Filename: strings.TrimPrefix(file, "/workspace/"), Sha256Hex: hexSum, Size: &size, Mode: &mode}.Build()},
	}.Build())
	if err != nil {
		return errs.Wrap(errs.CodeVMM, err, "write workspace file")
	}
	return nil
}

// DeleteWorkspace (vmm.WorkspaceWriter): remove a file or folder of a stopped project.
func (a *Adapter) DeleteWorkspace(ctx context.Context, id, p string) error {
	target, err := workspaceDir(p)
	if err != nil {
		return err
	}
	if target == "/workspace" {
		return errs.InvalidArgument("cannot delete the workspace root")
	}
	if live := a.liveSandbox(id); live != nil {
		out, err := a.exec(ctx, live, "rm -rf "+shQuote(target))
		if err != nil || !strings.HasPrefix(out, "exit=0") {
			return errs.New(errs.CodeVMM, "delete failed: "+out)
		}
		return nil
	}
	api, vol, err := a.volume(ctx, id)
	if err != nil {
		return err
	}
	_, err = api.VolumeRemoveFile(ctx, pb.VolumeRemoveFileRequest_builder{VolumeId: vol, Path: strings.TrimPrefix(target, "/workspace/"), Recursive: true}.Build())
	if err != nil {
		return errs.Wrap(errs.CodeVMM, err, "delete workspace file")
	}
	return nil
}

// reloadAwake makes a running computer see what was just written to its volume.
func (a *Adapter) reloadAwake(ctx context.Context, id string) {
	if live := a.liveSandbox(id); live != nil {
		_ = live.ReloadVolumes(ctx, &modal.SandboxReloadVolumesParams{Timeout: 10 * time.Second})
	}
}

// keepFile holds a folder made while the computer is stopped: the volume
// keeps files, and a folder exists while something is in it.
const keepFile = ".keep"

// MakeWorkspaceDir (vmm.WorkspaceOrganizer): make a folder and its parents.
func (a *Adapter) MakeWorkspaceDir(ctx context.Context, id, p string) error {
	dir, err := workspaceDir(p)
	if err != nil {
		return err
	}
	if dir == "/workspace" {
		return nil
	}
	if live := a.liveSandbox(id); live != nil {
		out, err := a.exec(ctx, live, "mkdir -p "+shQuote(dir))
		if err != nil || !strings.HasPrefix(out, "exit=0") {
			return errs.New(errs.CodeVMM, "mkdir failed: "+out)
		}
		return nil
	}
	return a.WriteWorkspace(ctx, id, dir+"/"+keepFile, nil)
}

// MoveWorkspace (vmm.WorkspaceOrganizer): move or rename a file or folder:
// copied on the volume, then the original removed.
func (a *Adapter) MoveWorkspace(ctx context.Context, id, from, to string) error {
	src, err := workspaceDir(from)
	if err != nil {
		return err
	}
	dst, err := workspaceDir(to)
	if err != nil {
		return err
	}
	if src == "/workspace" || dst == "/workspace" {
		return errs.InvalidArgument("cannot move the workspace root")
	}
	if live := a.liveSandbox(id); live != nil {
		out, err := a.exec(ctx, live, `[ -e `+shQuote(src)+` ] || exit 4; [ -e `+shQuote(dst)+` ] && exit 3; mkdir -p "$(dirname `+shQuote(dst)+`)" && mv -- `+shQuote(src)+` `+shQuote(dst))
		switch {
		case err != nil:
			return err
		case strings.HasPrefix(out, "exit=3"):
			return vmm.ErrExists
		case strings.HasPrefix(out, "exit=4"):
			return errs.NotFound("workspace path")
		case !strings.HasPrefix(out, "exit=0"):
			return errs.New(errs.CodeVMM, "move failed: "+out)
		}
		return nil
	}
	// The destination must not be there: a copy onto a folder would land
	// inside it.
	if _, err := a.ListWorkspace(ctx, id, dst); err == nil {
		return vmm.ErrExists
	}
	if _, err := a.ReadWorkspace(ctx, id, dst); err == nil {
		return vmm.ErrExists
	}
	api, vol, err := a.volume(ctx, id)
	if err != nil {
		return err
	}
	rel := func(p string) string { return strings.TrimPrefix(p, "/workspace/") }
	if _, err := api.VolumeCopyFiles(ctx, pb.VolumeCopyFilesRequest_builder{VolumeId: vol, SrcPaths: []string{rel(src)}, DstPath: rel(dst), Recursive: true}.Build()); err != nil {
		if status.Code(err) == codes.NotFound {
			return errs.NotFound("workspace path")
		}
		return errs.Wrap(errs.CodeVMM, err, "move workspace file")
	}
	if _, err := api.VolumeRemoveFile(ctx, pb.VolumeRemoveFileRequest_builder{VolumeId: vol, Path: rel(src), Recursive: true}.Build()); err != nil {
		return errs.Wrap(errs.CodeVMM, err, "move workspace file")
	}
	return nil
}

func workspaceDir(p string) (string, error) {
	clean := path.Clean("/workspace/" + strings.TrimPrefix(p, "/"))
	if clean != "/workspace" && !strings.HasPrefix(clean, "/workspace/") {
		return "", errs.InvalidArgument("path is outside the workspace")
	}
	return clean, nil
}

func shQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// liveSandbox is the project's sandbox when it is running, else nil.
func (a *Adapter) liveSandbox(id string) *modal.Sandbox {
	a.mu.Lock()
	defer a.mu.Unlock()
	if st, ok := a.sandboxes[id]; ok && !st.slept {
		return st.sb
	}
	return nil
}

// volume returns Modal's API and the id of the volume behind a project computer.
func (a *Adapter) volume(ctx context.Context, id string) (pb.ModalClientClient, string, error) {
	a.mu.Lock()
	st, ok := a.sandboxes[id]
	var spec vmm.VMSpec
	if ok {
		spec = st.spec
	}
	a.mu.Unlock()
	name := workspaceVolumeName(spec)
	if !ok || name == "" {
		return nil, "", errs.New(errs.CodeUnavailable, "this computer keeps no files while stopped")
	}
	api, err := a.api(ctx)
	if err != nil {
		return nil, "", err
	}
	a.mu.Lock()
	vol := a.volumeIDs[name]
	a.mu.Unlock()
	if vol == "" {
		v, err := a.client.Volumes.FromName(ctx, name, &modal.VolumeFromNameParams{CreateIfMissing: true})
		if err != nil {
			return nil, "", errs.Wrap(errs.CodeVMM, err, "modal workspace volume")
		}
		vol = v.VolumeID
		a.mu.Lock()
		if a.volumeIDs == nil {
			a.volumeIDs = map[string]string{}
		}
		a.volumeIDs[name] = vol
		a.mu.Unlock()
	}
	return api, vol, nil
}

// api is Modal's gRPC API on the connection the client itself uses (captured by
// an interceptor the first time it makes a call), so its authentication applies.
func (a *Adapter) api(ctx context.Context) (pb.ModalClientClient, error) {
	if a.client == nil {
		return nil, errs.New(errs.CodeUnavailable, "modal client not initialized")
	}
	if a.conn.Load() == nil {
		// Any call makes the client connect; this one is cheap and idempotent.
		if _, err := a.client.Apps.FromName(ctx, sandboxApp, &modal.AppFromNameParams{CreateIfMissing: true}); err != nil {
			return nil, errs.Wrap(errs.CodeVMM, err, "modal app")
		}
	}
	conn := a.conn.Load()
	if conn == nil {
		return nil, errs.New(errs.CodeUnavailable, "modal connection unavailable")
	}
	return pb.NewModalClientClient(conn), nil
}

func download(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "download workspace file")
	}
	defer res.Body.Close()
	return io.ReadAll(io.LimitReader(res.Body, maxReadBytes+1))
}

// --- through a running computer ---

func (a *Adapter) listViaExec(ctx context.Context, sb *modal.Sandbox, dir string) ([]vmm.WorkspaceEntry, error) {
	out, err := a.exec(ctx, sb, `cd `+shQuote(dir)+` 2>/dev/null || exit 3; find . -mindepth 1 -maxdepth 1 -printf '%y|%s|%f\n'`)
	if err != nil {
		return nil, err
	}
	body, ok := strings.CutPrefix(out, "exit=0\n")
	if !ok {
		return nil, errs.NotFound("workspace directory")
	}
	entries := []vmm.WorkspaceEntry{}
	for _, line := range strings.Split(body, "\n") {
		parts := strings.SplitN(line, "|", 3)
		if len(parts) != 3 || parts[2] == "" {
			continue
		}
		switch parts[0] {
		case "d":
			entries = append(entries, vmm.WorkspaceEntry{Name: parts[2], Type: "dir"})
		case "f":
			size, _ := strconv.ParseInt(parts[1], 10, 64)
			entries = append(entries, vmm.WorkspaceEntry{Name: parts[2], Type: "file", Size: size})
		}
	}
	return entries, nil
}

func (a *Adapter) readViaExec(ctx context.Context, sb *modal.Sandbox, file string) ([]byte, error) {
	q := shQuote(file)
	out, err := a.exec(ctx, sb, `[ -f `+q+` ] || exit 3; [ "$(stat -c %s `+q+`)" -le `+strconv.Itoa(maxReadBytes)+` ] || exit 4; base64 -w0 `+q)
	if err != nil {
		return nil, err
	}
	switch {
	case strings.HasPrefix(out, "exit=4"):
		return nil, errs.InvalidArgument("file exceeds 32 MiB")
	case !strings.HasPrefix(out, "exit=0\n"):
		return nil, errs.NotFound("workspace file")
	}
	return base64.StdEncoding.DecodeString(strings.TrimSpace(strings.TrimPrefix(out, "exit=0\n")))
}

func (a *Adapter) writeViaExec(ctx context.Context, sb *modal.Sandbox, file string, data []byte) error {
	// In chunks, so a large file never exceeds the command line.
	q := shQuote(file)
	const chunk = 48 * 1024
	for i := 0; i < len(data) || i == 0; i += chunk {
		end := min(i+chunk, len(data))
		redirect := ">"
		if i > 0 {
			redirect = ">>"
		}
		cmd := `mkdir -p "$(dirname ` + q + `)" && printf '%s' '` + base64.StdEncoding.EncodeToString(data[i:end]) + `' | base64 -d ` + redirect + ` ` + q
		out, err := a.exec(ctx, sb, cmd)
		if err != nil || !strings.HasPrefix(out, "exit=0") {
			return errs.New(errs.CodeVMM, "write failed: "+out)
		}
	}
	return nil
}
