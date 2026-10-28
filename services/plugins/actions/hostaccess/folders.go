package hostaccess

import (
	"context"
	"encoding/json"
	"path"
	"strings"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/untrusted"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	hm "github.com/aseman/aseman/plugins/actions/hostaccess/models"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Shared folders come from the person's project computers: a folder of one
// project's workspace, shared with the person's own agents in every project.
// They never leave the sandbox: reads and writes go to that computer's files
// as the person, with the person's own permission in that project checked on
// every call.

// ProjectFiles reaches a project computer's workspace (the spaces namespace).
type ProjectFiles interface {
	ProjectFiles(ctx context.Context, caller identity.ID, space, operation, p, content string) (map[string]any, error)
}

type bridgedFiles struct{ s *Service }

func (b bridgedFiles) ProjectFiles(ctx context.Context, caller identity.ID, space, operation, p, content string) (map[string]any, error) {
	var out map[string]any
	err := bridge.Invoke(ctx, b.s.K, "spaces", "ProjectFiles", []any{ctx, caller, space, operation, p, content}, &out)
	return out, err
}

// folderTools are the agent tools over shared folders.
var folderTools = []string{"folder_list", "folder_read", "folder_write"}

// hostTools are the agent tools over a person's own computer.
var hostTools = []string{"host_exec", "host_read", "host_write", "host_list"}

// Settings is the node's host access switch (off unless an administrator
// turned it on).
func (s *Service) Settings(ctx context.Context) hm.Settings {
	var rows []hm.Settings
	if err := s.R.List(ctx, "hostaccess_settings", database.Filter{Limit: 1}, &rows); err != nil || len(rows) == 0 {
		return hm.Settings{}
	}
	return rows[0]
}

// HostEnabled reports whether agents may use people's own computers at all.
func (s *Service) HostEnabled(ctx context.Context) bool { return s.Settings(ctx).HostEnabled }

// SetHostEnabled turns host access on or off for the whole node. Turning it
// off also turns off every registered computer, so turning it back on does
// not silently reconnect them: each person turns theirs on again.
func (s *Service) SetHostEnabled(ctx context.Context, admin identity.ID, on bool) (hm.Settings, error) {
	st := s.Settings(ctx)
	now := s.now().UTC()
	st.HostEnabled, st.UpdatedBy, st.UpdatedAt = on, admin.String(), now
	if st.ID.IsZero() {
		id, err := identity.New(s.K.NodeID())
		if err != nil {
			return st, err
		}
		st.Entity = entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}
		if err := s.R.CreateID(ctx, "hostaccess_settings", id, &st); err != nil {
			return st, err
		}
	} else if err := s.R.Update(ctx, "hostaccess_settings", st.ID, &st); err != nil {
		return st, err
	}
	if !on {
		var hosts []hm.Host
		if err := s.R.List(ctx, "hosts", database.Filter{Equal: map[string]any{"enabled": true}, Limit: 10000}, &hosts); err == nil {
			for i := range hosts {
				hosts[i].Enabled, hosts[i].UpdatedAt = false, now
				_ = s.R.Update(ctx, "hosts", hosts[i].ID, &hosts[i])
			}
		}
	}
	return st, nil
}

func (s *Service) requireHost(ctx context.Context) error {
	if !s.HostEnabled(ctx) {
		return errs.Permission("access to people's own computers is off on this node; share folders from a project computer instead")
	}
	return nil
}

// cleanFolder is a workspace-relative folder path ("" for the whole
// workspace), refusing anything that leaves the workspace.
func cleanFolder(p string) (string, error) {
	p = strings.TrimSpace(strings.ReplaceAll(p, `\`, "/"))
	p = strings.Trim(strings.TrimPrefix(p, "/workspace"), "/")
	for _, part := range strings.Split(p, "/") {
		if part == ".." {
			return "", errs.InvalidArgument("a shared folder is a path inside the project's workspace")
		}
	}
	return strings.TrimPrefix(path.Clean("/"+p), "/"), nil
}

// ShareFolder shares a folder of one of the person's project computers with
// their own agents everywhere. The person must be able to read the project
// (and, for write access, to work in it).
func (s *Service) ShareFolder(ctx context.Context, owner identity.ID, space, folder, name, access string) (*hm.SharedFolder, error) {
	if _, err := identity.Parse(space); err != nil {
		return nil, errs.InvalidArgument("invalid project")
	}
	folder, err := cleanFolder(folder)
	if err != nil {
		return nil, err
	}
	if access != hm.AccessWrite {
		access = hm.AccessRead
	}
	if s.Files == nil {
		return nil, errs.New(errs.CodeUnavailable, "project computers are not available")
	}
	// Looking at it checks the person may read the project.
	out, err := s.Files.ProjectFiles(ctx, owner, space, "list", folder, "")
	if err != nil {
		return nil, err
	}
	if out["missing"] == true {
		return nil, errs.NotFound("that folder is not on the project's computer")
	}
	name = clip(name, 80)
	if name == "" {
		name = path.Base("/" + folder)
		if folder == "" {
			name = "workspace"
		}
	}
	var rows []hm.SharedFolder
	_ = s.R.List(ctx, "shared_folders", database.Filter{Equal: map[string]any{"owner_id": owner.String(), "space_id": space, "path": folder}, Limit: 1}, &rows)
	now := s.now().UTC()
	if len(rows) > 0 {
		f := rows[0]
		f.Name, f.Access, f.Enabled, f.UpdatedAt = name, access, true, now
		return &f, s.R.Update(ctx, "shared_folders", f.ID, &f)
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	f := hm.SharedFolder{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, OwnerID: owner.String(), SpaceID: space,
		Path: folder, Name: name, Access: access, Enabled: true}
	return &f, s.R.CreateID(ctx, "shared_folders", id, &f)
}

// Folders lists the person's shared folders.
func (s *Service) Folders(ctx context.Context, owner string) ([]hm.SharedFolder, error) {
	var rows []hm.SharedFolder
	return rows, s.R.List(ctx, "shared_folders", database.Filter{Equal: map[string]any{"owner_id": owner}, OrderBy: "created_at", Asc: true, Limit: 200}, &rows)
}

func (s *Service) folder(ctx context.Context, owner, id string) (*hm.SharedFolder, error) {
	fid, err := identity.Parse(id)
	if err != nil {
		return nil, errs.InvalidArgument("invalid folder")
	}
	var f hm.SharedFolder
	if err := s.R.Get(ctx, "shared_folders", fid, &f); err != nil {
		return nil, err
	}
	if f.OwnerID != owner {
		return nil, errs.NotFound("folder")
	}
	return &f, nil
}

// SetFolder changes a shared folder's access or turns it off.
func (s *Service) SetFolder(ctx context.Context, owner identity.ID, id, access string, enabled bool) (*hm.SharedFolder, error) {
	f, err := s.folder(ctx, owner.String(), id)
	if err != nil {
		return nil, err
	}
	if access == hm.AccessRead || access == hm.AccessWrite {
		f.Access = access
	}
	f.Enabled, f.UpdatedAt = enabled, s.now().UTC()
	return f, s.R.Update(ctx, "shared_folders", f.ID, f)
}

// Unshare stops sharing a folder.
func (s *Service) Unshare(ctx context.Context, owner identity.ID, id string) error {
	f, err := s.folder(ctx, owner.String(), id)
	if err != nil {
		return err
	}
	return s.R.Delete(ctx, "shared_folders", f.ID)
}

// within joins a path to a shared folder, refusing anything outside it.
func within(f *hm.SharedFolder, p string) (string, error) {
	p = strings.TrimPrefix(strings.ReplaceAll(strings.TrimSpace(p), `\`, "/"), "/")
	joined := path.Clean("/" + path.Join(f.Path, p))
	root := path.Clean("/" + f.Path)
	if joined != root && !strings.HasPrefix(joined, strings.TrimSuffix(root, "/")+"/") {
		return "", errs.Permission("outside the shared folder " + f.Name)
	}
	return strings.TrimPrefix(joined, "/"), nil
}

// folderFor finds the enabled shared folder an agent names (id or name).
func (s *Service) folderFor(ctx context.Context, owner, ref string) (*hm.SharedFolder, error) {
	rows, err := s.Folders(ctx, owner)
	if err != nil {
		return nil, err
	}
	for i := range rows {
		if rows[i].Enabled && (rows[i].ID.String() == ref || strings.EqualFold(rows[i].Name, ref)) {
			return &rows[i], nil
		}
	}
	return nil, errs.NotFound("no shared folder called " + ref + "; folder_list names them")
}

// folderTool serves folder_list, folder_read and folder_write.
func (s *Service) folderTool(ctx context.Context, call gate.ToolCall) (string, error) {
	if s.Files == nil {
		return "", errs.New(errs.CodeUnavailable, "project computers are not available")
	}
	owner, err := identity.Parse(call.ActorID)
	if err != nil {
		return "", errs.Permission("shared folders belong to the person the agent works for")
	}
	var args struct {
		Folder  string `json:"folder"`
		Path    string `json:"path"`
		Content string `json:"content"`
	}
	_ = json.Unmarshal([]byte(call.Args), &args)
	if call.Tool == "folder_list" && args.Folder == "" {
		rows, err := s.Folders(ctx, call.ActorID)
		if err != nil {
			return "", err
		}
		var b strings.Builder
		for _, f := range rows {
			if f.Enabled {
				b.WriteString(f.Name + " (" + f.Access + ")\n")
			}
		}
		if b.Len() == 0 {
			return "The person has not shared any folders.", nil
		}
		return b.String(), nil
	}
	f, err := s.folderFor(ctx, call.ActorID, args.Folder)
	if err != nil {
		return "", err
	}
	target, err := within(f, args.Path)
	if err != nil {
		return "", err
	}
	switch call.Tool {
	case "folder_list":
		out, err := s.Files.ProjectFiles(ctx, owner, f.SpaceID, "list", target, "")
		if err != nil {
			return "", err
		}
		raw, _ := json.Marshal(out["items"])
		return untrusted.Wrap("shared folder "+f.Name, string(raw)), nil
	case "folder_read":
		out, err := s.Files.ProjectFiles(ctx, owner, f.SpaceID, "read", target, "")
		if err != nil {
			return "", err
		}
		if out["missing"] == true {
			return "", errs.NotFound("no such file in " + f.Name)
		}
		content, _ := out["content"].(string)
		return untrusted.Wrap("shared folder "+f.Name, content), nil
	case "folder_write":
		if f.Access != hm.AccessWrite {
			return "", errs.Permission(f.Name + " is shared read-only")
		}
		out, err := s.Files.ProjectFiles(ctx, owner, f.SpaceID, "write", target, args.Content)
		if err != nil {
			return "", err
		}
		if out["ok"] == false {
			msg, _ := out["error"].(string)
			return "", errs.New(errs.CodeUnavailable, msg)
		}
		return "Wrote " + args.Path + " in " + f.Name, nil
	}
	return "", errs.NotFound("tool " + call.Tool)
}
