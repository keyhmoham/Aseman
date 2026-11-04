package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"log"
	"net/http"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Code Mode (Cloudflare's MCP pattern) is the agent's capability-calling
// system: instead of loading every app function, platform tool and timeline
// query into the model context, agents write JavaScript against one OpenAPI
// document. The node exposes search + execute as a built-in MCP server;
// model-written code runs in an isolated JS sandbox whose only outbound path
// is codemode.request.
//
// Paths in the generated document:
//
//	POST /apps/{slug}/{function}   JSON body = microtool arguments
//	POST /apps/{slug}/ask          JSON body = {request} for apps without microtools
//	POST /platform/{tool}          JSON body = platform tool arguments (files,
//	                               proxies, routines, desk, UI, db, …)
//	POST /timeline/{tool}          JSON body = timeline MCP tool arguments
//	POST /sandbox/{op}             the shared computer (codemode_workspace.go)
//	POST /agents/{name}            the space's agents as subagents (codemode_workspace.go)
//
// Harness tools (messaging, ask_user, sandbox FS/shell, planning, swarm) stay
// as native LLM tools — they own interrupts, the shared computer and turn UX.
//
// External MCP clients (including a Cloudflare Worker wrapping openApiMcpServer)
// use /tools/v1/codemode/{openapi,request} with the caller's credentials.

const codeModeGatewayPrefix = "/tools/v1/codemode"

// Roughly Cloudflare's ~6,000-token search/execute response budget.
const codeModeResultMaxChars = 24_000

var codeModeSlug = regexp.MustCompile(`[^a-z0-9_]+`)

// Platform builtins served through Code Mode (not as one LLM tool each).
// sandbox_exec / file_edit stay on the runtime's sandbox shell and files; message_send,
// room_info and ask_user stay as native communication / HITL tools; file_read
// stays the agent's native read_attachment, because an image it returns is
// vision input only as a tool result, not as Code Mode's text result.
// ui_present (AG-UI in chat or as a desk window) is here too: with Code Mode
// on, the agents reach it only as /platform/ui_present.
var codeModePlatform = map[string]bool{
	"file_send": true, "file_upload": true, "image_generate": true, "ui_present": true,
	"proxy_create": true, "proxy_list": true, "proxy_get": true, "proxy_delete": true,
	"appui_create": true, "appui_publish": true, "appui_status": true,
	"routine_create": true, "routine_list": true, "routine_get": true, "routine_update": true, "routine_delete": true,
	"desk_state": true, "desk_arrange": true, "desk_close": true,
	"db_tables": true, "db_read": true,
	// Served by other namespaces, offered while they are available.
	"secret_request": true, "computer_help": true, "offer_task": true, "task_update": true,
	"host_exec": true, "host_read": true, "host_write": true, "host_list": true,
	"folder_list": true, "folder_read": true, "folder_write": true,
	"slack_post": true, "teams_post": true, "sms_send": true,
	"responsibility_create": true, "responsibility_list": true,
}

// CodeModeRequest is one authenticated API call from sandbox code (or from the
// Cloudflare Worker request callback).
type CodeModeRequest struct {
	Method      string         `json:"method"`
	Path        string         `json:"path"`
	Query       map[string]any `json:"query,omitempty"`
	Body        any            `json:"body,omitempty"`
	ContentType string         `json:"contentType,omitempty"`
	RawBody     bool           `json:"rawBody,omitempty"`
}

type codeModeApp struct {
	Slug        string
	BotID       string
	Name        string
	Description string
	Commands    []vmm.ToolCommand
}

// CodeModeOpenAPI builds an OpenAPI 3 document of the space's capability
// surface for Code Mode search/execute (apps, platform tools, timeline).
func (s *Service) CodeModeOpenAPI(ctx context.Context, spaceID string) (map[string]any, error) {
	apps, err := s.codeModeApps(ctx, spaceID)
	if err != nil {
		return nil, err
	}
	paths := map[string]any{}
	tags := codeModeTags(apps)
	for _, app := range apps {
		codeModeAddAppPaths(paths, app)
	}
	for _, t := range codeModePlatformTools(ctx, s, spaceID) {
		p := "/platform/" + t.Name
		schema := t.Parameters
		if schema == nil {
			schema = map[string]any{"type": "object", "properties": map[string]any{}}
		}
		desc := t.Description
		if t.Usage != "" {
			desc = desc + "\n" + t.Usage
		}
		paths[p] = map[string]any{
			"post": map[string]any{
				"operationId": "platform__" + t.Name,
				"summary":     t.Name,
				"description": desc,
				"tags":        []string{"platform", t.Name},
				"requestBody": map[string]any{
					"required": true,
					"content":  map[string]any{"application/json": map[string]any{"schema": schema}},
				},
				"responses": map[string]any{"200": map[string]any{"description": "Platform tool result"}},
			},
		}
	}
	tags = append(tags, map[string]any{"name": "platform", "description": "Aseman platform tools (files, proxies, routines, desk, UI, database)"})
	if codeModeAddSandboxPaths(ctx, paths) {
		tags = append(tags, map[string]any{"name": "sandbox", "description": "The space's shared computer: shell and files under /workspace (whole jobs in one call)"})
	}
	if agents, err := s.codeModeAgents(ctx, spaceID); err != nil {
		log.Printf("codemode: agents unavailable for %s (%v); omitting /agents paths", spaceID, err)
	} else if len(agents) > 0 {
		codeModeAddAgentPaths(paths, agents)
		tags = append(tags, map[string]any{"name": "agents", "description": "The space's agents as subagents: hand a task, get the answer"})
	}
	if timelinePaths, timelineTags, ok := s.codeModeTimelinePaths(ctx, spaceID); ok {
		for p, op := range timelinePaths {
			paths[p] = op
		}
		tags = append(tags, timelineTags...)
	}
	return map[string]any{
		"openapi": "3.1.0",
		"info": map[string]any{
			"title":   "Aseman Code Mode",
			"version": "1.0.0",
			"description": "Capability surface for Cloudflare Code Mode search/execute: " +
				"POST /apps/{slug}/{function}, POST /platform/{tool}, POST /timeline/{tool}, " +
				"POST /sandbox/{op} (shared computer), POST /agents/{name} (the space's agents). " +
				"Use search to discover paths, then execute with codemode.request. " +
				"Compose calls in the sandbox; only the return value enters the model context.",
		},
		"paths": paths,
		"tags":  tags,
	}, nil
}

func codeModeAddAppPaths(paths map[string]any, app codeModeApp) {
	if len(app.Commands) == 0 {
		p := "/apps/" + app.Slug + "/ask"
		paths[p] = map[string]any{
			"post": map[string]any{
				"operationId": app.Slug + "__ask",
				"summary":     "Ask " + app.Name + " in natural language",
				"description": app.Description,
				"tags":        []string{app.Slug, app.Name, "apps"},
				"requestBody": map[string]any{
					"required": true,
					"content": map[string]any{
						"application/json": map[string]any{
							"schema": map[string]any{
								"type": "object",
								"properties": map[string]any{
									"request": map[string]any{"type": "string", "description": "Natural-language request for this app"},
								},
								"required": []string{"request"},
							},
						},
					},
				},
				"responses": map[string]any{"200": map[string]any{"description": "App reply"}},
			},
		}
		return
	}
	for _, cmd := range app.Commands {
		fn := codeModeSlug.ReplaceAllString(strings.ToLower(cmd.Name), "_")
		fn = strings.Trim(fn, "_")
		if fn == "" {
			continue
		}
		p := "/apps/" + app.Slug + "/" + fn
		schema := cmd.Schema
		if schema == nil {
			schema = map[string]any{"type": "object", "properties": map[string]any{}}
		}
		desc := cmd.Description
		if desc == "" {
			desc = cmd.Name + " of " + app.Name
		}
		paths[p] = map[string]any{
			"post": map[string]any{
				"operationId":       app.Slug + "__" + fn,
				"summary":           desc,
				"description":       "[" + app.Name + "] " + desc,
				"tags":              []string{app.Slug, app.Name, "apps"},
				"requestBody":       map[string]any{"required": true, "content": map[string]any{"application/json": map[string]any{"schema": schema}}},
				"responses":         map[string]any{"200": map[string]any{"description": "Microtool result"}},
				"x-aseman-bot":      app.BotID,
				"x-aseman-function": cmd.Name,
			},
		}
	}
}

func codeModeTags(apps []codeModeApp) []map[string]any {
	out := make([]map[string]any, 0, len(apps)+1)
	out = append(out, map[string]any{"name": "apps", "description": "Connected apps of this space"})
	for _, app := range apps {
		out = append(out, map[string]any{"name": app.Slug, "description": app.Name + ": " + app.Description})
	}
	return out
}

// codeModePlatformTools are the platform builtins (and admin db tools) listed
// for this space that Code Mode exposes under /platform/{name}.
func codeModePlatformTools(ctx context.Context, s *Service, spaceID string) []vmm.Tool {
	sid, err := identity.Parse(spaceID)
	if err != nil {
		return nil
	}
	var listed []vmm.Tool
	if err := bridge.Invoke(ctx, s.K, "spaces", "SpaceTools", []any{ctx, sid, identity.ID{}}, &listed); err != nil {
		// Fall back to the static builtin schemas when SpaceTools is unavailable.
		log.Printf("codemode: SpaceTools unavailable for %s (%v); using Builtins schemas", spaceID, err)
		out := make([]vmm.Tool, 0, len(codeModePlatform))
		for _, t := range vmm.Builtins() {
			if codeModePlatform[t.Name] {
				out = append(out, t)
			}
		}
		return out
	}
	out := make([]vmm.Tool, 0, len(listed))
	seen := map[string]bool{}
	for _, t := range listed {
		if !codeModePlatform[t.Name] || seen[t.Name] {
			continue
		}
		seen[t.Name] = true
		out = append(out, t)
	}
	return out
}

func (s *Service) codeModeTimelinePaths(ctx context.Context, spaceID string) (map[string]any, []map[string]any, bool) {
	raw, err := s.codeModeTimelineRPC(ctx, spaceID, map[string]any{"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
	if err != nil {
		log.Printf("codemode: timeline tools/list unavailable for %s (%v); omitting /timeline paths", spaceID, err)
		return nil, nil, false
	}
	var msg struct {
		Result struct {
			Tools []struct {
				Name        string         `json:"name"`
				Description string         `json:"description"`
				InputSchema map[string]any `json:"inputSchema"`
			} `json:"tools"`
		} `json:"result"`
	}
	if json.Unmarshal(raw, &msg) != nil || len(msg.Result.Tools) == 0 {
		return nil, nil, false
	}
	paths := map[string]any{}
	for _, t := range msg.Result.Tools {
		if t.Name == "" {
			continue
		}
		schema := t.InputSchema
		if schema == nil {
			schema = map[string]any{"type": "object", "properties": map[string]any{}}
		}
		paths["/timeline/"+t.Name] = map[string]any{
			"post": map[string]any{
				"operationId": "timeline__" + t.Name,
				"summary":     t.Name,
				"description": t.Description,
				"tags":        []string{"timeline", t.Name},
				"requestBody": map[string]any{
					"required": true,
					"content":  map[string]any{"application/json": map[string]any{"schema": schema}},
				},
				"responses": map[string]any{"200": map[string]any{"description": "Timeline tool result"}},
			},
		}
	}
	return paths, []map[string]any{{"name": "timeline", "description": "Project timeline (dated history of the space)"}}, true
}

func (s *Service) codeModeTimelineRPC(ctx context.Context, spaceID string, message map[string]any) ([]byte, error) {
	body, err := json.Marshal(message)
	if err != nil {
		return nil, err
	}
	var out []byte
	if err := bridge.Invoke(ctx, s.K, "timeline", "MCP", []any{ctx, spaceID, body}, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// CodeModeRequestCall runs one authenticated capability call for Code Mode execute.
func (s *Service) CodeModeRequestCall(ctx context.Context, spaceID string, opts CodeModeRequest) (result any, err error) {
	if opts.Method == "" {
		opts.Method = "POST"
	}
	if !strings.EqualFold(opts.Method, "POST") {
		return nil, errs.InvalidArgument("Code Mode paths are called with POST")
	}
	path := opts.Path
	if !strings.HasPrefix(path, "/") {
		return nil, errs.InvalidArgument("API path must start with a slash")
	}
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) < 2 {
		return nil, errs.InvalidArgument("path must be /apps/{slug}/{function}, /platform/{tool}, /timeline/{tool}, /sandbox/{op} or /agents/{name}")
	}
	payload, err := codeModeBody(opts.Body, opts.RawBody)
	if err != nil {
		return nil, err
	}
	// Every well-formed request is an agent action: decided, recorded, and
	// run with the person's secrets put in; what comes back hides them.
	if n, ok := codeModePathParts[parts[0]]; ok && len(parts) == n {
		var decision gate.Result
		if payload, decision, err = s.gateCodeMode(ctx, spaceID, parts, payload); err != nil {
			return nil, err
		}
		defer func() { result = s.redactCodeMode(ctx, decision, result, err) }()
	}
	switch parts[0] {
	case "apps":
		if len(parts) != 3 {
			return nil, errs.InvalidArgument("path must be /apps/{slug}/{function}")
		}
		return s.codeModeCallApp(ctx, spaceID, parts[1], parts[2], payload)
	case "platform":
		if len(parts) != 2 {
			return nil, errs.InvalidArgument("path must be /platform/{tool}")
		}
		return s.codeModeCallPlatform(ctx, spaceID, parts[1], payload)
	case "timeline":
		if len(parts) != 2 {
			return nil, errs.InvalidArgument("path must be /timeline/{tool}")
		}
		return s.codeModeCallTimeline(ctx, spaceID, parts[1], payload)
	case "sandbox":
		if len(parts) != 2 {
			return nil, errs.InvalidArgument("path must be /sandbox/{op}")
		}
		return s.codeModeCallSandbox(ctx, spaceID, parts[1], payload)
	case "agents":
		if len(parts) != 2 {
			return nil, errs.InvalidArgument("path must be /agents/{name}")
		}
		return s.codeModeCallAgent(ctx, spaceID, parts[1], payload)
	default:
		return nil, errs.InvalidArgument("path must start with /apps, /platform, /timeline, /sandbox or /agents")
	}
}

// codeModePathParts is how many segments each Code Mode path has.
var codeModePathParts = map[string]int{"apps": 3, "platform": 2, "timeline": 2, "sandbox": 2, "agents": 2}

func (s *Service) codeModeCallApp(ctx context.Context, spaceID, slug, fn string, payload map[string]any) (any, error) {
	apps, err := s.codeModeApps(ctx, spaceID)
	if err != nil {
		return nil, err
	}
	var app *codeModeApp
	for i := range apps {
		if apps[i].Slug == slug {
			app = &apps[i]
			break
		}
	}
	if app == nil {
		return nil, errs.NotFound("app " + slug)
	}
	var body string
	if fn == "ask" && len(app.Commands) == 0 {
		req, _ := payload["request"].(string)
		if req == "" {
			b, _ := json.Marshal(payload)
			req = string(b)
		}
		body = req
	} else {
		real := fn
		for _, cmd := range app.Commands {
			if codeModeSlug.ReplaceAllString(strings.ToLower(cmd.Name), "_") == fn || strings.EqualFold(cmd.Name, fn) {
				real = cmd.Name
				break
			}
		}
		raw, _ := json.Marshal(map[string]any{"function": real, "payload": payload})
		body = string(raw)
	}
	reply, err := s.InvokeTool(ctx, app.BotID, body)
	if err != nil {
		return nil, err
	}
	var parsed any
	if json.Unmarshal([]byte(reply), &parsed) == nil {
		return unwrapMCPResult(parsed), nil
	}
	return reply, nil
}

func (s *Service) codeModeCallPlatform(ctx context.Context, spaceID, toolName string, payload map[string]any) (any, error) {
	if !codeModePlatform[toolName] {
		return nil, errs.NotFound("platform tool " + toolName)
	}
	argsJSON, err := json.Marshal(payload)
	if err != nil {
		return nil, errs.InvalidArgument("body must be a JSON object")
	}
	agentName := s.codeModeAgentName(ctx)
	var result string
	if err := bridge.Invoke(ctx, s.K, "spaces", "ToolDispatch", []any{ctx, spaceID, agentName, toolName, string(argsJSON)}, &result); err != nil {
		return nil, err
	}
	var parsed any
	if json.Unmarshal([]byte(result), &parsed) == nil {
		return parsed, nil
	}
	return result, nil
}

func (s *Service) codeModeCallTimeline(ctx context.Context, spaceID, toolName string, payload map[string]any) (any, error) {
	raw, err := s.codeModeTimelineRPC(ctx, spaceID, map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "tools/call",
		"params":  map[string]any{"name": toolName, "arguments": payload},
	})
	if err != nil {
		return nil, err
	}
	var msg map[string]any
	if json.Unmarshal(raw, &msg) != nil {
		return string(raw), nil
	}
	if errObj, ok := msg["error"]; ok && errObj != nil {
		return nil, errs.New(errs.CodeUnavailable, fmt.Sprint(errObj))
	}
	result, _ := msg["result"].(map[string]any)
	if result == nil {
		return msg["result"], nil
	}
	return unwrapMCPResult(result), nil
}

func (s *Service) codeModeAgentName(ctx context.Context) string {
	exec := vmm.ExecutionFrom(ctx)
	if exec.AgentID != "" {
		if rec, err := s.bot(ctx, exec.AgentID); err == nil && rec.Name != "" {
			return rec.Name
		}
	}
	return "codemode"
}

func codeModeBody(body any, raw bool) (map[string]any, error) {
	if body == nil {
		return map[string]any{}, nil
	}
	if raw {
		switch v := body.(type) {
		case string:
			var m map[string]any
			if err := json.Unmarshal([]byte(v), &m); err != nil {
				return nil, errs.InvalidArgument("rawBody must be JSON object text")
			}
			return m, nil
		default:
			return nil, errs.InvalidArgument("rawBody must be a string")
		}
	}
	switch v := body.(type) {
	case map[string]any:
		return v, nil
	default:
		b, err := json.Marshal(v)
		if err != nil {
			return nil, errs.InvalidArgument("body must be a JSON object")
		}
		var m map[string]any
		if err := json.Unmarshal(b, &m); err != nil {
			return nil, errs.InvalidArgument("body must be a JSON object")
		}
		return m, nil
	}
}

func unwrapMCPResult(v any) any {
	m, ok := v.(map[string]any)
	if !ok {
		return v
	}
	if sc := m["structuredContent"]; sc != nil {
		return sc
	}
	if contents, ok := m["content"].([]any); ok {
		var texts []string
		for _, c := range contents {
			cm, _ := c.(map[string]any)
			if cm != nil && cm["type"] == "text" {
				texts = append(texts, fmt.Sprint(cm["text"]))
			}
		}
		if len(texts) == 1 {
			var parsed any
			if json.Unmarshal([]byte(texts[0]), &parsed) == nil {
				return parsed
			}
			return texts[0]
		}
		if len(texts) > 1 {
			return strings.Join(texts, "\n")
		}
	}
	return v
}

func (s *Service) codeModeApps(ctx context.Context, spaceID string) ([]codeModeApp, error) {
	if spaceID == "" {
		return nil, errs.InvalidArgument("space required")
	}
	sid, err := identity.Parse(spaceID)
	if err != nil {
		return nil, err
	}
	var tools []vmm.Tool
	if err := bridge.Invoke(ctx, s.K, "spaces", "SpaceTools", []any{ctx, sid, identity.ID{}}, &tools); err != nil {
		return nil, err
	}
	used := map[string]bool{}
	out := make([]codeModeApp, 0, len(tools))
	for _, t := range tools {
		if t.Kind != "tool" || t.BotID == "" || t.Name == "sandbox_exec" {
			continue
		}
		// Skip the sandbox computer listing; shell is not an MCP app.
		if strings.Contains(strings.ToLower(t.Description), "shared computer (sandbox)") {
			continue
		}
		slug := codeModeSlug.ReplaceAllString(strings.ToLower(t.Name), "_")
		slug = strings.Trim(slug, "_")
		if slug == "" {
			slug = "app"
		}
		base := slug
		for i := 2; used[slug]; i++ {
			slug = fmt.Sprintf("%s_%d", base, i)
		}
		used[slug] = true
		out = append(out, codeModeApp{
			Slug: slug, BotID: t.BotID, Name: t.Name, Description: t.Description, Commands: t.Commands,
		})
	}
	return out, nil
}

// CodeModeMCP serves one MCP JSON-RPC message: initialize, tools/list, and
// tools/call for search and execute (Cloudflare Code Mode search-and-execute).
func (s *Service) CodeModeMCP(ctx context.Context, spaceID string, body []byte) ([]byte, error) {
	var msg struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      any             `json:"id"`
		Method  string          `json:"method"`
		Params  json.RawMessage `json:"params"`
	}
	if err := json.Unmarshal(body, &msg); err != nil {
		return nil, errs.InvalidArgument("invalid MCP message")
	}
	reply := func(result any) ([]byte, error) {
		return json.Marshal(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": result})
	}
	fail := func(code int, message string) ([]byte, error) {
		return json.Marshal(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "error": map[string]any{"code": code, "message": message}})
	}
	switch msg.Method {
	case "initialize":
		return reply(map[string]any{
			"protocolVersion": "2025-06-18",
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": "aseman-codemode", "version": "1.0.0"},
		})
	case "notifications/initialized":
		return []byte(`{"jsonrpc":"2.0","result":{}}`), nil
	case "ping":
		return reply(map[string]any{})
	case "tools/list":
		return reply(map[string]any{"tools": codeModeToolDefs()})
	case "tools/call":
		var p struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		}
		if err := json.Unmarshal(msg.Params, &p); err != nil || p.Name == "" {
			return fail(-32602, "tools/call needs name and arguments")
		}
		code, _ := p.Arguments["code"].(string)
		if strings.TrimSpace(code) == "" {
			return fail(-32602, "code is required")
		}
		spec, err := s.CodeModeOpenAPI(ctx, spaceID)
		if err != nil {
			return fail(-32000, err.Error())
		}
		var result any
		switch p.Name {
		case "search":
			result, err = runCodeModeJS(code, spec, nil)
		case "execute":
			result, err = runCodeModeJS(code, spec, func(opts CodeModeRequest) (any, error) {
				return s.CodeModeRequestCall(ctx, spaceID, opts)
			})
		default:
			return fail(-32602, "unknown tool "+p.Name)
		}
		if err != nil {
			return reply(map[string]any{
				"content": []map[string]any{{"type": "text", "text": err.Error()}},
				"isError": true,
			})
		}
		text := codeModeText(result)
		out := map[string]any{
			"content": []map[string]any{{"type": "text", "text": text}},
			"isError": false,
		}
		if m, ok := result.(map[string]any); ok {
			out["structuredContent"] = m
		}
		return reply(out)
	default:
		return fail(-32601, "method not found: "+msg.Method)
	}
}

func codeModeToolDefs() []map[string]any {
	codeSchema := map[string]any{
		"type": "object",
		"properties": map[string]any{
			"code": map[string]any{
				"type": "string",
				"description": "JavaScript function that returns a value, e.g. () => { ... }. " +
					"async/await in Cloudflare-style snippets is accepted and run as sync host calls in the node sandbox.",
			},
		},
		"required": []string{"code"},
	}
	searchDesc := `Search the OpenAPI capability surface without calling anything.
Write JavaScript that inspects codemode.spec() and returns only the paths, methods, parameters or schemas you need.
Paths: /apps/{slug}/{function}, /platform/{tool}, /timeline/{tool}, /sandbox/{op}, /agents/{name}.
Example:
() => {
  const spec = codemode.spec();
  return Object.entries(spec.paths)
    .filter(([path]) => path.includes("/weather") || path.startsWith("/platform/"))
    .map(([path, ops]) => ({ path, methods: Object.keys(ops) }));
}
(async () => { const spec = await codemode.spec(); ... } is also accepted; await is stripped to sync.)
The full OpenAPI document stays in the sandbox; only your return value enters the model context.`

	executeDesc := `Execute JavaScript against this space's capability surface (Cloudflare Code Mode).
This is how agents call connected apps, platform tools, the shared computer, the
project timeline and the space's other agents — not as one LLM tool each.
codemode.spec() returns the OpenAPI document. codemode.request({method, path, body}) calls:
  POST /apps/{slug}/{function}  — connected app microtools
  POST /platform/{tool}         — files, proxies, routines, desk, UI, apps (appui_*), database, …
  POST /timeline/{tool}         — project timeline reads
  POST /sandbox/{op}            — the shared computer: exec {command, cwd}, write_files {files, dir},
                                  read_files {paths, dir}, edit_file, list, delete (under /workspace)
  POST /agents/{name}           — hand a task to another agent of the space; returns {agent, answer}
codemode.batch([{path, body}, …]) runs independent calls at the same time and returns
[{ok, result} | {ok:false, error}] in order (fan out to several agents, apps or checks).
Do the whole job in one call when you can: write every file, run the tests and checks,
publish, and return a short summary (exit codes, failures, paths). Compose, branch and
loop on results in the code; intermediates never enter the model context.
Credentials never enter the sandbox.
Example:
() => {
  const dir = "/workspace/apps/todo";
  codemode.request({ method: "POST", path: "/sandbox/write_files", body: { dir, files: [
    { path: "server.js", content: "…" },
    { path: "test/server.test.js", content: "…" },
  ] } });
  const test = codemode.request({ method: "POST", path: "/sandbox/exec", body: { cwd: dir, command: "npm test 2>&1 | tail -30" } });
  if (test.exit_code !== 0) return { failed: "tests", output: test.output };
  const [review, weather] = codemode.batch([
    { path: "/agents/researcher", body: { task: "List 5 must-have todo features, one line each" } },
    { path: "/apps/weather/weather_report", body: { city: "London" } },
  ]);
  return { tests: "passed", review: review.ok ? review.result.answer : review.error, weather: weather.ok && weather.result };
}`

	return []map[string]any{
		{"name": "search", "description": searchDesc, "inputSchema": codeSchema},
		{"name": "execute", "description": executeDesc, "inputSchema": codeSchema},
	}
}

func codeModeText(v any) string {
	var text string
	switch t := v.(type) {
	case string:
		text = t
	default:
		b, err := json.MarshalIndent(v, "", "  ")
		if err != nil {
			text = fmt.Sprint(v)
		} else {
			text = string(b)
		}
	}
	if utf8.RuneCountInString(text) > codeModeResultMaxChars {
		r := []rune(text)
		text = string(r[:codeModeResultMaxChars]) + "\n--- TRUNCATED ---"
	}
	return text
}

// --- HTTP for Cloudflare Workers / external MCP hosts -----------------------

func (s *Service) serveCodeModeOpenAPI(ctx context.Context, req *network.Request) (*network.Response, error) {
	spaceID := header(req.Header, "X-Aseman-Space")
	if spaceID == "" {
		return errorJSON(errs.InvalidArgument("X-Aseman-Space required")), nil
	}
	ctx, err := s.codeModeAuth(ctx, req, spaceID)
	if err != nil {
		return errorJSON(err), nil
	}
	spec, err := s.CodeModeOpenAPI(ctx, spaceID)
	if err != nil {
		return errorJSON(err), nil
	}
	b, _ := json.Marshal(spec)
	return &network.Response{Status: http.StatusOK, Header: map[string]string{"Content-Type": "application/json"}, Body: b}, nil
}

func (s *Service) serveCodeModeRequest(ctx context.Context, req *network.Request) (*network.Response, error) {
	spaceID := header(req.Header, "X-Aseman-Space")
	if spaceID == "" {
		return errorJSON(errs.InvalidArgument("X-Aseman-Space required")), nil
	}
	ctx, err := s.codeModeAuth(ctx, req, spaceID)
	if err != nil {
		return errorJSON(err), nil
	}
	var opts CodeModeRequest
	if err := json.Unmarshal(req.Body, &opts); err != nil {
		return errorJSON(errs.InvalidArgument("invalid request body")), nil
	}
	out, err := s.CodeModeRequestCall(ctx, spaceID, opts)
	if err != nil {
		return errorJSON(err), nil
	}
	b, _ := json.Marshal(out)
	return &network.Response{Status: http.StatusOK, Header: map[string]string{"Content-Type": "application/json"}, Body: b}, nil
}

func (s *Service) serveCodeModeHTTP(ctx context.Context, req *network.Request) (*network.Response, error) {
	spaceID := header(req.Header, "X-Aseman-Space")
	if spaceID == "" {
		return errorJSON(errs.InvalidArgument("X-Aseman-Space required")), nil
	}
	ctx, err := s.codeModeAuth(ctx, req, spaceID)
	if err != nil {
		return errorJSON(err), nil
	}
	out, err := s.CodeModeMCP(ctx, spaceID, req.Body)
	if err != nil {
		return errorJSON(err), nil
	}
	return &network.Response{Status: http.StatusOK, Header: map[string]string{"Content-Type": "application/json"}, Body: out}, nil
}

// codeModeAuth resolves the caller's session (or an already-scoped actor) and
// checks space membership. Sets execution scope so InvokeTool / ToolDispatch
// act as that person (and in the optional room from X-Aseman-Room).
func (s *Service) codeModeAuth(ctx context.Context, req *network.Request, spaceID string) (context.Context, error) {
	sid, err := identity.Parse(spaceID)
	if err != nil {
		return ctx, err
	}
	actor := helper.Actor(ctx)
	if actor.IsZero() {
		token := bearer(req.Header)
		if token == "" {
			return ctx, errs.Unauthenticated("sign in to use Code Mode")
		}
		acc, err := helper.SessionAccount(ctx, s.R, token)
		if err != nil {
			return ctx, err
		}
		actor = acc.ID
		ctx = helper.WithActor(ctx, actor)
	}
	roomHeader := header(req.Header, "X-Aseman-Room")
	roomID := identity.ID{}
	if roomHeader != "" {
		parsed, err := identity.Parse(roomHeader)
		if err != nil {
			return ctx, errs.InvalidArgument("invalid X-Aseman-Room")
		}
		roomID = parsed
	}
	if err := helper.CheckSpaceAccess(ctx, s.R, actor, sid, roomID, true); err != nil {
		return ctx, err
	}
	exec := vmm.ExecutionFrom(ctx)
	exec.ActorID = actor.String()
	exec.SpaceID = spaceID
	if roomHeader != "" {
		exec.RoomID = roomHeader
		ctx = vmm.WithRoom(ctx, roomHeader)
	}
	return vmm.WithExecution(ctx, exec), nil
}

func errorJSON(err error) *network.Response {
	code := http.StatusBadRequest
	switch errs.CodeOf(err) {
	case errs.CodeUnauthenticated:
		code = http.StatusUnauthorized
	case errs.CodePermission:
		code = http.StatusForbidden
	case errs.CodeNotFound:
		code = http.StatusNotFound
	case errs.CodeUnavailable:
		code = http.StatusServiceUnavailable
	}
	b, _ := json.Marshal(map[string]any{"error": err.Error(), "code": string(errs.CodeOf(err))})
	return &network.Response{Status: code, Header: map[string]string{"Content-Type": "application/json"}, Body: b}
}
