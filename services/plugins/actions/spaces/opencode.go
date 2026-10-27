package spaces

// The OpenCode switch: who builds the node's on-demand apps (appui_create)
// and does the spaces' other programming. On, OpenCode does, in each space's
// sandbox: agents brief it (appui_create, opencode_run) and it plans, builds,
// tests and repairs. Off (the default), OpenCode is out of the loop: the
// space's own agents build apps with the same project layout, guides,
// toolchain (the Elpian validator and headless driver as aseman-elpian) and
// platform checks (appui_publish), and write any other code themselves.
// Admins turn it on or off (Admin → OpenCode); the next turn follows it.

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// openCodeTable is the database model of the OpenCode switch.
const openCodeTable = "spaces_opencode"

// OpenCodeSetting is the node's OpenCode switch.
type OpenCodeSetting struct {
	ID        string    `db:"id" json:"-"`
	Enabled   bool      `db:"enabled" json:"enabled"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}

func (s *Service) openCodeID() string { return s.K.NodeID().String() + "opencode" }

// OpenCode returns the stored switch (off when never set).
func (s *Service) OpenCode(ctx context.Context) (*OpenCodeSetting, error) {
	var o OpenCodeSetting
	err := s.R.GetString(ctx, openCodeTable, s.openCodeID(), &o)
	if errs.CodeOf(err) == errs.CodeNotFound {
		return &OpenCodeSetting{ID: s.openCodeID()}, nil
	}
	if err != nil {
		return nil, err
	}
	return &o, nil
}

// OpenCodeEnabled reports whether OpenCode builds apps and does the coding
// (read by the agent runtime adapter for each turn's prompts).
func (s *Service) OpenCodeEnabled(ctx context.Context) (bool, error) {
	o, err := s.OpenCode(ctx)
	if err != nil {
		return false, err
	}
	return o.Enabled, nil
}

// openCodeOn is OpenCodeEnabled for the tools: unreadable means off.
func (s *Service) openCodeOn(ctx context.Context) bool {
	on, err := s.OpenCodeEnabled(ctx)
	return err == nil && on
}

// SetOpenCode turns OpenCode on or off for the whole node.
func (s *Service) SetOpenCode(ctx context.Context, enabled bool) (*OpenCodeSetting, error) {
	o, err := s.OpenCode(ctx)
	if err != nil {
		return nil, err
	}
	creating := o.UpdatedAt.IsZero()
	o.Enabled, o.UpdatedAt = enabled, time.Now().UTC()
	if creating {
		err = s.R.DB.Create(ctx, openCodeTable, o.ID, o)
	} else {
		err = s.R.DB.Update(ctx, openCodeTable, o.ID, o)
	}
	if err != nil {
		return nil, err
	}
	return o, nil
}

// openCodeView renders the switch for the admin panel.
func (s *Service) openCodeView(ctx context.Context) (map[string]any, error) {
	o, err := s.OpenCode(ctx)
	if err != nil {
		return nil, err
	}
	view := map[string]any{"enabled": o.Enabled, "updated_at": o.UpdatedAt}
	if o.Enabled {
		view["builder"] = "opencode"
		view["status"] = "On: OpenCode builds, tests and repairs on-demand apps and does every coding task in the spaces' sandboxes, briefed by the agents; the platform verifies each app before it opens."
	} else {
		view["builder"] = "agents"
		view["status"] = "Off: the spaces' own agents build, test and repair on-demand apps (and write any other code) with the same project layout, guides, Elpian validator and headless driver; the platform verifies each app before it opens. OpenCode is not used."
	}
	return view, nil
}

// openCodeActions are the admin actions of the OpenCode switch.
func openCodeActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "spaces", Name: "opencode_get", Summary: "Admin: whether OpenCode builds on-demand apps",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
					return nil, err
				}
				view, err := s.openCodeView(ctx)
				if err != nil {
					return nil, err
				}
				return helper.JSON(view)
			}},
		helper.Action{Namespace: "spaces", Name: "opencode_set", Summary: "Admin: turn OpenCode on or off for on-demand apps and coding",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
					return nil, err
				}
				var in struct {
					Enabled *bool `json:"enabled"`
				}
				if err := helper.Decode(req, &in); err != nil {
					return nil, err
				}
				if in.Enabled == nil {
					return nil, errs.InvalidArgument("opencode_set needs enabled (true or false)")
				}
				if _, err := s.SetOpenCode(ctx, *in.Enabled); err != nil {
					return nil, err
				}
				view, err := s.openCodeView(ctx)
				if err != nil {
					return nil, err
				}
				return helper.JSON(view)
			}},
	}
}

// errOpenCodeOff answers an OpenCode tool called while OpenCode is off.
func errOpenCodeOff(tool string) error {
	return errs.New(errs.CodeUnavailable, tool+" is unavailable: OpenCode is turned off on this node. "+
		"Build it yourself: appui_create prepares an app for you (or your team) to build, test and publish with appui_publish; "+
		"write any other code directly in the sandbox; read a project's state with appui_status.")
}
