package tools

// MCP Apps: an MCP tool can declare a ui:// resource (an HTML app) its
// results are shown with. The device runs that app in a sandboxed frame and
// is its host; what the app asks of its server (its resources, its tools)
// comes through tools.app_rpc, as the person, in the space, like every
// other call of the tool.

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/tools/models"
)

// appResourceTTL is how long an app's HTML is kept (apps are large and the
// same for everyone).
const appResourceTTL = 10 * time.Minute

type appResource struct {
	result map[string]any
	at     time.Time
}

var (
	appResourceMu sync.Mutex
	appResources  = map[string]appResource{}
)

// appRPC implements tools.app_rpc: one request of a tool's app to its
// server — resources/read (its HTML and other resources) or tools/call —
// or "app": the app a microtool's results are shown with.
func (s *Service) appRPC(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireAuthenticated(req); e != nil {
		return nil, e
	}
	var in struct {
		Bot    string         `json:"bot"`
		Space  string         `json:"space"`
		Room   string         `json:"room"`
		Method string         `json:"method"`
		Params map[string]any `json:"params"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	tool, c, err := s.frontendScope(ctx, req, in.Bot, in.Space, in.Room)
	if err != nil {
		return nil, err
	}
	if in.Params == nil {
		in.Params = map[string]any{}
	}
	switch in.Method {
	case "tools/call":
		name, _ := in.Params["name"].(string)
		if name == "" {
			return nil, errs.InvalidArgument("tools/call needs a tool name")
		}
		args, _ := in.Params["arguments"].(map[string]any)
		if args == nil {
			args = map[string]any{}
		}
		result, err := s.callRaw(ctx, c, tool.BotID, name, args)
		if err != nil {
			// An app is told a failure as a tool error, the way MCP reports one.
			return helper.JSON(map[string]any{"isError": true, "content": []any{map[string]any{"type": "text", "text": err.Error()}}})
		}
		return helper.JSON(result)
	case "app":
		// The app a microtool's results are shown with: its ui:// resource,
		// read.
		microtool, _ := in.Params["microtool"].(string)
		commands, err := s.CommandsFor(ctx, tool.BotID, req.Caller.ID.String(), in.Space)
		if err != nil {
			return nil, err
		}
		uri := ""
		for _, c := range commands {
			if c["name"] == microtool {
				uri, _ = c["ui"].(string)
			}
		}
		if uri == "" {
			return nil, errs.NotFound(microtool + " has no app")
		}
		result, err := s.readAppResource(ctx, tool, req.Caller.ID.String(), in.Space, uri)
		if err != nil {
			return nil, err
		}
		return helper.JSON(map[string]any{"uri": uri, "resource": result})
	case "resources/read":
		uri, _ := in.Params["uri"].(string)
		if uri == "" {
			return nil, errs.InvalidArgument("resources/read needs a uri")
		}
		result, err := s.readAppResource(ctx, tool, req.Caller.ID.String(), in.Space, uri)
		if err != nil {
			return nil, err
		}
		return helper.JSON(result)
	}
	return nil, errs.InvalidArgument("an app may ask its server for resources/read or tools/call")
}

// readAppResource reads one resource of a tool's server as [actor] (kept a
// few minutes: apps are large and the same for everyone).
func (s *Service) readAppResource(ctx context.Context, tool *models.Tool, actor, space, uri string) (map[string]any, error) {
	key := tool.BotID + "|" + uri
	if tool.Auth == "user" {
		key += "|" + actor
	}
	appResourceMu.Lock()
	hit, ok := appResources[key]
	appResourceMu.Unlock()
	if ok && time.Since(hit.at) < appResourceTTL {
		return hit.result, nil
	}
	rec, err := s.bot(ctx, tool.BotID)
	if err != nil {
		return nil, err
	}
	actorID, err := identity.Parse(actor)
	if err != nil {
		return nil, errs.InvalidArgument("invalid caller")
	}
	ep, err := s.endpointFor(ctx, tool, rec, actorID, space)
	if err != nil {
		return nil, err
	}
	result, err := s.rpc(ctx, ep, "resources/read", map[string]any{"uri": uri})
	if err != nil {
		return nil, err
	}
	appResourceMu.Lock()
	for k, v := range appResources {
		if time.Since(v.at) >= appResourceTTL {
			delete(appResources, k)
		}
	}
	appResources[key] = appResource{result: result, at: time.Now()}
	appResourceMu.Unlock()
	return result, nil
}

// callRaw runs one microtool as [call] does and returns the MCP result as
// the server gave it (content blocks, structured content, error flag).
func (s *Service) callRaw(ctx context.Context, c caller, botID, microtool string, args map[string]any) (map[string]any, error) {
	body, _ := json.Marshal(map[string]any{"function": microtool, "payload": args})
	raw, _ := json.Marshal(map[string]any{"space": c.Space, "room": c.Room, "bot": botID, "body": string(body)})
	resp, err := s.K.Actions().Dispatch(ctx, "spaces", "ask", &api.ActionRequest{Caller: c.Caller, Body: raw})
	if err != nil {
		return nil, err
	}
	var answer struct {
		Reply string `json:"reply"`
	}
	if err := json.Unmarshal(resp.Body, &answer); err != nil {
		return nil, err
	}
	var result map[string]any
	if json.Unmarshal([]byte(answer.Reply), &result) != nil || result == nil {
		result = map[string]any{"content": []any{map[string]any{"type": "text", "text": answer.Reply}}}
	}
	return result, nil
}
