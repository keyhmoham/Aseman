package tools

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/actions/tools/models"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// gateCodeMode decides one Code Mode request before it runs, through the same
// gate as every other agent action: a script that composes ten calls is ten
// decisions, each recorded. It returns the payload to run (with the person's
// secrets put in) and the decision, for redacting what comes back.
func (s *Service) gateCodeMode(ctx context.Context, spaceID string, parts []string, payload map[string]any) (map[string]any, gate.Result, error) {
	raw, _ := json.Marshal(payload)
	exec := vmm.ExecutionFrom(ctx)
	req := gate.Request{Args: raw, SpaceID: spaceID, RoomID: codeModeRoom(ctx), AgentID: exec.AgentID, AgentName: s.codeModeAgentName(ctx)}
	switch parts[0] {
	case "apps":
		req.Kind, req.Tool, req.App, req.Function = gate.KindApp, parts[1]+"/"+parts[2], parts[1], parts[2]
		s.codeModeAppHints(ctx, spaceID, &req)
	case "platform":
		req.Kind, req.Tool = gate.KindTool, parts[1]
	case "timeline":
		req.Kind, req.Tool, req.Effect = gate.KindTool, "timeline_"+parts[1], gate.EffectRead
	case "sandbox":
		req.Kind, req.Tool = gate.KindSandbox, "sandbox_"+parts[1]
		switch parts[1] {
		case "exec":
			req.Tool = "sandbox_exec"
			req.Command, _ = payload["command"].(string)
		case "read_files", "list":
			req.Effect = gate.EffectRead
		case "delete":
			req.Effect = gate.EffectWrite
		default:
			req.Effect = gate.EffectWrite
		}
	case "agents":
		req.Kind, req.Tool, req.App = gate.KindAgent, "agent_handoff", parts[1]
		req.Text, _ = payload["task"].(string)
	}
	res, err := gate.Check(ctx, s.K, req)
	if err != nil {
		return nil, res, err
	}
	out := payload
	if len(res.Args) > 0 && string(res.Args) != string(raw) {
		var substituted map[string]any
		if json.Unmarshal(res.Args, &substituted) == nil {
			out = substituted
		}
	}
	if req.Kind == gate.KindSandbox && res.Command != "" {
		out["command"] = res.Command
	}
	return out, res, nil
}

// codeModeAppHints marks an app call as an external MCP server's tool and
// carries the tool's own read-only / destructive hints.
func (s *Service) codeModeAppHints(ctx context.Context, spaceID string, req *gate.Request) {
	apps, err := s.codeModeApps(ctx, spaceID)
	if err != nil {
		return
	}
	for _, app := range apps {
		if app.Slug != req.App {
			continue
		}
		var tool models.Tool
		if s.R.GetString(ctx, "tool_registry", app.BotID, &tool) == nil && tool.EffectiveMode() == models.ModeExternal {
			req.Kind, req.MCPServer, req.URL = gate.KindMCP, app.Name, tool.URL
		}
		for _, cmd := range app.Commands {
			if !strings.EqualFold(codeModeSlug.ReplaceAllString(strings.ToLower(cmd.Name), "_"), req.Function) && !strings.EqualFold(cmd.Name, req.Function) {
				continue
			}
			req.MCPTool = cmd.Name
			if v, ok := cmd.Annotations["readOnlyHint"].(bool); ok {
				req.ReadOnly = &v
			}
			if v, ok := cmd.Annotations["destructiveHint"].(bool); ok {
				req.Destroys = &v
			}
		}
		return
	}
}

// redactCodeMode hides the person's secrets in a Code Mode result.
func (s *Service) redactCodeMode(ctx context.Context, res gate.Result, out any, callErr error) any {
	if res.AuditID == "" && len(res.Secrets) == 0 {
		return out
	}
	raw, _ := json.Marshal(out)
	text := gate.Finish(ctx, s.K, res, string(raw), callErr)
	if len(res.Secrets) == 0 {
		return out
	}
	var redacted any
	if json.Unmarshal([]byte(text), &redacted) == nil {
		return redacted
	}
	return text
}
