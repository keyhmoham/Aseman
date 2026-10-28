package google

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	gm "github.com/aseman/aseman/plugins/actions/google/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

func (s *Service) actions() []api.Action {
	a := func(name, summary string, h func(context.Context, *api.ActionRequest) (*api.ActionResponse, error)) api.Action {
		return helper.Action{Namespace: "google", Name: name, Summary: summary, Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireUser(req); err != nil {
				return nil, err
			}
			return h(ctx, req)
		}}
	}
	return []api.Action{
		a("status", "My Google connection (and whether the node offers one)", s.status),
		a("connect_start", "Start connecting my Google account: the consent URL to open", s.connectStart),
		a("connect_finish", "Finish connecting with the code and state Google returned (native apps)", s.connectFinish),
		a("disconnect", "Disconnect my Google account", s.disconnect),
		a("admin_get", "Admin: the node's Google OAuth client", s.adminGet),
		a("admin_set", "Admin: set the node's Google OAuth client and turn it on or off", s.adminSet),
	}
}

func (s *Service) status(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	st, _, err := s.settings(ctx)
	offered := err == nil && st.Enabled
	out := map[string]any{"offered": offered, "connected": false, "fake": s.endpoints().Fake}
	if c, err := s.connection(ctx, req.Caller.ID.String()); err == nil {
		out["connected"] = c.Status == gm.StatusConnected
		out["connection"] = c
	}
	return helper.JSON(out)
}

func (s *Service) connectStart(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Return string `json:"return,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	u, err := s.StartConnect(ctx, req.Caller.ID, in.Return)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"url": u, "redirect_uri": redirectURI()})
}

func (s *Service) connectFinish(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		State string `json:"state"`
		Code  string `json:"code"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	c, _, err := s.FinishConnect(ctx, in.State, in.Code)
	if err != nil {
		return nil, err
	}
	if c.ID != req.Caller.ID {
		return nil, errs.Permission("this sign-in belongs to someone else")
	}
	return helper.JSON(map[string]any{"connection": c})
}

func (s *Service) disconnect(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := s.Disconnect(ctx, req.Caller.ID.String()); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

func (s *Service) adminGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if !s.isAdmin(ctx, req.Caller.ID) {
		return nil, errs.Permission("administrator required")
	}
	st, _, err := s.settings(ctx)
	configured := err == nil
	return helper.JSON(map[string]any{"enabled": configured && st.Enabled, "client_id": st.ClientID,
		"has_secret": configured && st.ClientSecret != "", "redirect_uri": redirectURI(), "scopes": Scopes, "fake": s.endpoints().Fake})
}

func (s *Service) adminSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if !s.isAdmin(ctx, req.Caller.ID) {
		return nil, errs.Permission("administrator required")
	}
	var in struct {
		Enabled      bool   `json:"enabled"`
		ClientID     string `json:"client_id"`
		ClientSecret string `json:"client_secret,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	st, err := s.SaveSettings(ctx, req.Caller.ID, in.Enabled, in.ClientID, in.ClientSecret)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"enabled": st.Enabled, "client_id": st.ClientID, "has_secret": st.ClientSecret != ""})
}
