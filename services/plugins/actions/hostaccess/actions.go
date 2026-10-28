package hostaccess

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

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
		a("register", "Let my agents use this computer (desktop app), limited to the folders I share", s.register),
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
