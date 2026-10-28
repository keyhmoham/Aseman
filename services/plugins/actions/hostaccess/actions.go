package hostaccess

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

func (s *Service) status(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	rows, err := s.Folders(ctx, req.Caller.ID.String())
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"host_enabled": s.HostEnabled(ctx), "folders": rows})
}

func (s *Service) folders(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	rows, err := s.Folders(ctx, req.Caller.ID.String())
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"folders": rows})
}

func (s *Service) folderShare(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space  string `json:"space"`
		Path   string `json:"path"`
		Name   string `json:"name,omitempty"`
		Access string `json:"access,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	f, err := s.ShareFolder(ctx, req.Caller.ID, in.Space, in.Path, in.Name, in.Access)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"folder": f})
}

func (s *Service) folderSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		ID      string `json:"id"`
		Access  string `json:"access,omitempty"`
		Enabled bool   `json:"enabled"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	f, err := s.SetFolder(ctx, req.Caller.ID, in.ID, in.Access, in.Enabled)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"folder": f})
}

func (s *Service) folderUnshare(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		ID string `json:"id"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if err := s.Unshare(ctx, req.Caller.ID, in.ID); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

func (s *Service) adminGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	hosts, _ := s.R.Count(ctx, "hosts", database.Filter{Equal: map[string]any{"enabled": true}})
	return helper.JSON(map[string]any{"settings": s.Settings(ctx), "connected_hosts": hosts})
}

func (s *Service) adminSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	var in struct {
		HostEnabled bool `json:"host_enabled"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	st, err := s.SetHostEnabled(ctx, req.Caller.ID, in.HostEnabled)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"settings": st})
}

func (s *Service) actions() []api.Action {
	a := func(name, summary string, h func(context.Context, *api.ActionRequest) (*api.ActionResponse, error)) api.Action {
		return helper.Action{Namespace: "hostaccess", Name: name, Summary: summary, Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireUser(req); err != nil {
				return nil, err
			}
			return h(ctx, req)
		}}
	}
	return []api.Action{
		a("status", "Whether this node lets agents use people's own computers, and my shared folders", s.status),
		a("folders", "The folders I share with my agents, from my projects' computers", s.folders),
		a("folder_share", "Share a folder of one of my project computers with my agents in every project (read, or read and write)", s.folderShare),
		a("folder_set", "Change a shared folder's access, or turn it off", s.folderSet),
		a("folder_unshare", "Stop sharing a folder", s.folderUnshare),
		a("admin_get", "Admin: whether agents may use people's own computers (off by default)", s.adminGet),
		a("admin_set", "Admin: let agents use people's own computers through the desktop app, or not", s.adminSet),
		a("register", "Let my agents use this computer (desktop app), limited to the folders I share; only while the node allows host access", s.register),
		a("hosts", "My computers my agents may use", s.hosts),
		a("set_enabled", "Turn a computer's access on or off", s.setEnabled),
		a("next", "Desktop app: wait for the next call for this computer (long poll)", s.next),
		a("result", "Desktop app: what this computer did with a call", s.result),
	}
}

func (s *Service) register(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Host     string   `json:"host,omitempty"`
		Name     string   `json:"name"`
		Platform string   `json:"platform"`
		Folders  []string `json:"folders"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	h, err := s.Register(ctx, req.Caller.ID, in.Host, in.Name, in.Platform, in.Folders)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"host": h})
}

func (s *Service) hosts(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	rows, err := s.Hosts(ctx, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"hosts": rows})
}

func (s *Service) setEnabled(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Host    string `json:"host"`
		Enabled bool   `json:"enabled"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	h, err := s.host(ctx, req.Caller.ID, in.Host)
	if err != nil {
		return nil, err
	}
	h.Enabled, h.UpdatedAt = in.Enabled, s.now().UTC()
	if err := s.R.Update(ctx, "hosts", h.ID, h); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"host": h})
}

func (s *Service) next(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Host string `json:"host"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	c, err := s.Next(ctx, req.Caller.ID, in.Host)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"call": c})
}

func (s *Service) result(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Call   string `json:"call"`
		Output string `json:"output"`
		Error  string `json:"error,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if err := s.Result(ctx, req.Caller.ID, in.Call, in.Output, in.Error); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}
