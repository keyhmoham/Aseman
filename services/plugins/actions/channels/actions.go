package channels

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	cm "github.com/aseman/aseman/plugins/actions/channels/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

func (s *Service) actions() []api.Action {
	a := func(name, summary string, h func(context.Context, *api.ActionRequest) (*api.ActionResponse, error)) api.Action {
		return helper.Action{Namespace: "channels", Name: name, Summary: summary, Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireUser(req); err != nil {
				return nil, err
			}
			return h(ctx, req)
		}}
	}
	return []api.Action{
		a("status", "Which channels the node offers, and which I linked", s.status),
		a("link_code", "A one-time code to send from Slack, Teams or my phone (\"link CODE\") to link it", s.linkCode),
		a("unlink", "Unlink one of my channels", s.unlink),
		a("binding_set", "Choose where a linked channel's messages run and whether it gets notices", s.bindingSet),
		a("admin_get", "Admin: the node's Slack, Teams and Twilio settings (no secrets)", s.adminGet),
		a("admin_set", "Admin: set up Slack, Teams or Twilio", s.adminSet),
	}
}

func (s *Service) status(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	offered := map[string]bool{}
	for _, p := range []string{cm.Slack, cm.Teams, cm.Twilio} {
		st, err := s.settings(ctx, p)
		offered[p] = err == nil && st.Enabled
	}
	rows, err := s.Bindings(ctx, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"offered": offered, "bindings": rows, "endpoints": map[string]string{
		cm.Slack: SlackEventsPath, "slack_actions": SlackActionsPath, cm.Teams: TeamsMessagesPath, cm.Twilio: TwilioSMSPath}})
}

func (s *Service) linkCode(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Provider string `json:"provider"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	code, err := s.LinkCode(ctx, req.Caller.ID, in.Provider)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"code": code, "send": "link " + code, "expires_in_minutes": 10})
}

func (s *Service) unlink(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		ID string `json:"id"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.ID)
	if err != nil {
		return nil, errs.InvalidArgument("invalid id")
	}
	if err := s.Unlink(ctx, req.Caller.ID, id); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

func (s *Service) bindingSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		ID     string `json:"id"`
		Space  string `json:"space,omitempty"`
		Room   string `json:"room,omitempty"`
		Notify bool   `json:"notify"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.ID)
	if err != nil {
		return nil, errs.InvalidArgument("invalid id")
	}
	var b cm.Binding
	if err := s.R.Get(ctx, "channel_bindings", id, &b); err != nil || b.AccountID != req.Caller.ID.String() {
		return nil, errs.NotFound("binding")
	}
	if in.Space != "" {
		space, err := identity.Parse(in.Space)
		if err != nil {
			return nil, errs.InvalidArgument("invalid project")
		}
		room, _ := identity.Parse(in.Room)
		if err := helper.CheckSpaceAccess(ctx, s.R, req.Caller.ID, space, room, true); err != nil {
			return nil, err
		}
	}
	b.SpaceID, b.RoomID, b.Notify, b.UpdatedAt = in.Space, in.Room, in.Notify, s.now().UTC()
	if err := s.R.Update(ctx, "channel_bindings", id, &b); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"binding": b})
}

func (s *Service) isAdmin(ctx context.Context, caller identity.ID) bool {
	var acc account.Account
	if s.R.Get(ctx, "accounts", caller, &acc) != nil || acc.Kind != account.KindUser {
		return false
	}
	return acc.Role == "admin" || (acc.Handle != "" && acc.Handle == s.K.Env()["admin_handle"])
}

func (s *Service) adminGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if !s.isAdmin(ctx, req.Caller.ID) {
		return nil, errs.Permission("administrator required")
	}
	out := map[string]any{}
	for _, p := range []string{cm.Slack, cm.Teams, cm.Twilio} {
		if st, err := s.settings(ctx, p); err == nil {
			out[p] = map[string]any{"enabled": st.Enabled, "app_id": st.AppID, "from": st.From, "tenant": st.Tenant,
				"has_secret": st.secret != "", "has_token": st.token != ""}
		} else {
			out[p] = map[string]any{"enabled": false}
		}
	}
	out["endpoints"] = map[string]string{cm.Slack: SlackEventsPath, "slack_actions": SlackActionsPath, cm.Teams: TeamsMessagesPath, cm.Twilio: TwilioSMSPath}
	return helper.JSON(out)
}

func (s *Service) adminSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if !s.isAdmin(ctx, req.Caller.ID) {
		return nil, errs.Permission("administrator required")
	}
	var in struct {
		Provider string `json:"provider"`
		Enabled  bool   `json:"enabled"`
		AppID    string `json:"app_id,omitempty"`
		From     string `json:"from,omitempty"`
		Tenant   string `json:"tenant,omitempty"`
		// Secret: Slack's signing secret, Teams' app password.
		Secret string `json:"secret,omitempty"`
		// Token: Slack's bot token, Twilio's auth token.
		Token string `json:"token,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	st, err := s.SaveSettings(ctx, req.Caller.ID, cm.Settings{Provider: in.Provider, Enabled: in.Enabled, AppID: in.AppID, From: in.From, Tenant: in.Tenant}, in.Secret, in.Token)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"provider": st.Provider, "enabled": st.Enabled})
}
