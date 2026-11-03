package tools

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/tools/models"
)

// A tool's frontend is what people use it through.
//
// A static frontend is an Elpian app: a program the device runs on the
// Elpian VM (bytecode) or QuickJS (source), calling the tool's microtools
// through tools.invoke.

// caller is who a frontend acts for, and where.
type caller struct {
	Caller api.Caller
	Space  string
	Room   string
}

func (s *Service) frontendScope(ctx context.Context, req *api.ActionRequest, botID, space, room string) (*models.Tool, caller, error) {
	id, err := identity.Parse(botID)
	if err != nil {
		return nil, caller{}, errs.InvalidArgument("invalid bot id")
	}
	var tool models.Tool
	if err := s.R.GetString(ctx, "tool_registry", id.String(), &tool); err != nil {
		return nil, caller{}, err
	}
	return &tool, caller{Caller: req.Caller, Space: space, Room: room}, nil
}

// frontendGet implements tools.frontend_get: a static frontend's program, or
// the mode string for any other / empty frontend.
func (s *Service) frontendGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireAuthenticated(req); e != nil {
		return nil, e
	}
	var in struct {
		Bot   string `json:"bot"`
		Space string `json:"space"`
		Room  string `json:"room"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	tool, _, err := s.frontendScope(ctx, req, in.Bot, in.Space, in.Room)
	if err != nil {
		return nil, err
	}
	var spec models.FrontendSpec
	_ = json.Unmarshal([]byte(tool.Frontend), &spec)
	mode := strings.TrimSpace(spec.Mode)
	out := map[string]any{"bot_id": tool.BotID, "mode": mode, "version": spec.Version}
	if mode == models.FrontendStatic {
		out["runtime"], out["language"] = spec.Runtime, spec.Language
		if spec.Runtime == models.RuntimeElpian {
			bytecode, err := s.entity(ctx, tool.BotID, models.EntityFrontendBytecode)
			if err != nil {
				return nil, err
			}
			out["bytecode"] = bytecode
		} else {
			source, err := s.entity(ctx, tool.BotID, models.EntityFrontendSource)
			if err != nil {
				return nil, err
			}
			out["source"] = source
		}
	}
	// A plugin's screen talks to the app through the plugin gate: say so to
	// those who may use it (wherever its window is opened).
	if p, err := s.plugin(ctx, tool.BotID); err == nil && req.Caller.Kind == "user" && s.usable(ctx, req.Caller.ID, p) == nil {
		out["plugin"] = p
	}
	return helper.JSON(out)
}
