package apihttp

// A web page an agent builds is served from the space's sandbox through a
// preview gateway (/v1/proxy/{id}/). Under its own prefix the gateway also
// answers the page's Aseman API itself, never forwarded to the sandbox:
//
//   - _aseman/api/<op>: the page's client for the Aseman API. It calls the
//     space's tools' microtools as the person viewing the page, in the
//     preview's space, the way a frontend calls its backend:
//     context, tools, microtools {tool}, call {tool, microtool, args},
//     agents, and ask {agent, body} for OpenUI agent-backed islands (each
//     ask runs in a temporary room thread of its own, deleted after).
//   - _aseman/kit/openui/*: the OpenUI component kit (JS/CSS) OpenCode mixes
//     into App UIs under the same Aseman theme tokens.
//
// Authorized like the rest of the preview: the person's session (the preview
// cookie after the first load) and membership of its space; requests that
// change something come from the preview's own page only.
//
// Interactive tool UIs use appui_create (OpenCode fullstack) shown as DeskWeb.

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"path"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/asemanopenui"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// pagePrefix is the part of a preview's path the gateway answers itself.
const pagePrefix = "_aseman/"

// proxyPage answers a preview's _aseman/ request (rest is the path after
// the prefix) for [acc], a member of the preview's space.
func (a *API) proxyPage(ctx context.Context, req *network.Request, p *proxy.Proxy, acc *account.Account, method, rest string) (*network.Response, error) {
	if kit, ok := strings.CutPrefix(rest, "kit/openui/"); ok {
		return pageOpenUIKit(method, kit)
	}
	if strings.HasPrefix(rest, "kit/") {
		return nil, errs.NotFound("no such kit; use kit/openui/ for the OpenUI component kit")
	}
	op, ok := strings.CutPrefix(rest, "api/")
	if !ok {
		return nil, errs.NotFound("no such page route")
	}
	if id, ok := strings.CutPrefix(op, "file/"); ok {
		return a.pageFile(ctx, acc, strings.Trim(id, "/"))
	}
	out, err := a.pageAPI(ctx, req, p, acc, method, strings.Trim(op, "/"))
	if err != nil {
		resp := a.errorResponse(err)
		resp.Header = map[string]string{"Content-Type": "application/json", "Cache-Control": "no-store"}
		return resp, nil
	}
	body, err := json.Marshal(out)
	if err != nil {
		return nil, errs.Wrap(errs.CodeInternal, err, "encode page api response")
	}
	return &network.Response{Status: http.StatusOK, Body: body, Header: map[string]string{
		"Content-Type": "application/json", "Cache-Control": "no-store",
	}}, nil
}

// pageFile serves a stored file the person may read (the page's images and
// media: a component's url naming /v1/files/<id>/content or the bare id).
func (a *API) pageFile(ctx context.Context, acc *account.Account, raw string) (*network.Response, error) {
	id, err := identity.Parse(raw)
	if err != nil {
		return nil, errs.InvalidArgument("invalid file id")
	}
	file, err := a.Spaces.GetFile(ctx, id)
	if err != nil {
		return nil, err
	}
	if err := a.Spaces.CanReadFile(ctx, file.ID, acc.ID); err != nil {
		return nil, err
	}
	data, err := a.Spaces.ReadFileBytes(ctx, file)
	if err != nil {
		return nil, err
	}
	ctype := file.Mime
	if ctype == "" {
		ctype = http.DetectContentType(data)
	}
	return &network.Response{Status: http.StatusOK, Body: data, Header: map[string]string{
		"Content-Type": ctype, "Cache-Control": "private, max-age=3600", "X-Content-Type-Options": "nosniff",
	}}, nil
}

// pageTool is one tool of the space as a page sees it.
type pageTool struct {
	Name        string           `json:"name"`
	ID          string           `json:"id"`
	Description string           `json:"description,omitempty"`
	Frontend    string           `json:"frontend,omitempty"`
	Microtools  []map[string]any `json:"microtools"`
}

func (a *API) pageAPI(ctx context.Context, req *network.Request, p *proxy.Proxy, acc *account.Account, method, op string) (any, error) {
	var in struct {
		Tool      string         `json:"tool"`
		Microtool string         `json:"microtool"`
		Args      map[string]any `json:"args"`
		Agent     string         `json:"agent"`
		Bot       string         `json:"bot"`
		Body      string         `json:"body"`
		Prompt    string         `json:"prompt"`
		History   []any          `json:"history"`
		// show: the desk window's title, rectangle and phone look.
		Title string         `json:"title"`
		Rect  map[string]any `json:"rect"`
	}
	if method != http.MethodGet && len(req.Body) > 0 {
		if err := json.Unmarshal(req.Body, &in); err != nil {
			return nil, errs.InvalidArgument("the request body must be a JSON object")
		}
	} else {
		in.Tool, in.Microtool = first(req.Query["tool"]), first(req.Query["microtool"])
		in.Agent, in.Bot = first(req.Query["agent"]), first(req.Query["bot"])
		in.Body, in.Prompt = first(req.Query["body"]), first(req.Query["prompt"])
		if raw := first(req.Query["args"]); raw != "" {
			if err := json.Unmarshal([]byte(raw), &in.Args); err != nil {
				return nil, errs.InvalidArgument("args must be a JSON object")
			}
		}
	}
	caller := api.Caller{ID: acc.ID, Kind: string(acc.Kind)}
	space := p.SpaceID.String()
	switch op {
	case "context":
		out := map[string]any{
			"space":   space,
			"user":    map[string]any{"id": acc.ID.String(), "handle": acc.Handle},
			"preview": map[string]any{"id": p.ID.String(), "title": p.Title, "path": p.GatewayPath()},
			"openui":  map[string]any{"kit": "_aseman/kit/openui/", "version": "1.1.0", "catalog": "catalog.spec.json"},
		}
		if !p.RoomID.IsZero() {
			out["room"] = p.RoomID.String()
		}
		return out, nil
	case "agents":
		agents, err := a.pageAgents(ctx, caller, space)
		if err != nil {
			return nil, err
		}
		return map[string]any{"agents": agents}, nil
	case "ask":
		if method == http.MethodGet {
			return nil, errs.InvalidArgument("ask an agent with POST")
		}
		agent := strings.TrimSpace(in.Agent)
		if agent == "" {
			agent = strings.TrimSpace(in.Bot)
		}
		body := strings.TrimSpace(in.Body)
		if body == "" {
			body = strings.TrimSpace(in.Prompt)
		}
		if agent == "" || body == "" {
			return nil, errs.InvalidArgument(`ask needs {"agent"|"bot", "body"|"prompt"}`)
		}
		rec, err := a.pageResolveAgent(ctx, caller, space, agent)
		if err != nil {
			return nil, err
		}
		// Every ask from an app is its own conversation: the agent works in a
		// temporary thread of the room, deleted when it is done, so apps never
		// mix their calls with each other or with the room's chat.
		askBody := map[string]any{"space": space, "bot": rec.ID, "body": body, "temp_thread": true}
		if !p.RoomID.IsZero() {
			askBody["room"] = p.RoomID.String()
		}
		if len(in.History) > 0 {
			askBody["history"] = in.History
		}
		var res struct {
			Reply string `json:"reply"`
			BotID string `json:"bot_id"`
		}
		if err := a.pageDispatch(ctx, caller, "spaces", "ask", askBody, &res); err != nil {
			return nil, err
		}
		return map[string]any{"agent": rec.Name, "bot_id": res.BotID, "reply": res.Reply}, nil
	case "tools":
		tools, err := a.pageTools(ctx, caller, space)
		if err != nil {
			return nil, err
		}
		return map[string]any{"tools": tools}, nil
	case "microtools":
		t, err := a.pageResolve(ctx, caller, space, in.Tool)
		if err != nil {
			return nil, err
		}
		var res struct {
			Commands []map[string]any `json:"commands"`
		}
		if err := a.pageDispatch(ctx, caller, "tools", "tool_microtools", map[string]any{"bot": t.ID, "space": space}, &res); err != nil {
			return nil, err
		}
		if res.Commands == nil {
			res.Commands = []map[string]any{}
		}
		return map[string]any{"tool": t.Name, "id": t.ID, "microtools": res.Commands}, nil
	case "call":
		if method == http.MethodGet {
			return nil, errs.InvalidArgument("call a microtool with POST")
		}
		if strings.TrimSpace(in.Microtool) == "" {
			return nil, errs.InvalidArgument(`call needs {"tool", "microtool", "args"}`)
		}
		t, err := a.pageResolve(ctx, caller, space, in.Tool)
		if err != nil {
			return nil, err
		}
		if in.Args == nil {
			in.Args = map[string]any{}
		}
		var res struct {
			Result any `json:"result"`
		}
		if err := a.pageDispatch(ctx, caller, "tools", "invoke", map[string]any{
			"bot": t.ID, "space": space, "function": in.Microtool, "payload": in.Args,
		}, &res); err != nil {
			return nil, err
		}
		// MCP backends return {content:[{type:text,text:…}]}; App UIs need the
		// unwrapped value (structuredContent, JSON text, or plain text).
		result, err := pageToolResult(res.Result)
		if err != nil {
			return nil, err
		}
		return map[string]any{"tool": t.Name, "microtool": in.Microtool, "result": result}, nil
	case "frontend":
		// Static frontend program, or mode metadata when empty/unknown.
		t, err := a.pageResolve(ctx, caller, space, in.Tool)
		if err != nil {
			return nil, err
		}
		body := map[string]any{"bot": t.ID, "space": space}
		if in.Microtool != "" {
			body["microtool"] = in.Microtool
		}
		if len(in.Args) > 0 {
			body["args"] = in.Args
		}
		var out map[string]any
		if err := a.pageDispatch(ctx, caller, "tools", "frontend_get", body, &out); err != nil {
			return nil, err
		}
		return out, nil
	case "show":
		// Opens a tool's frontend (on a result) as a card window on the
		// desk of the page's room, next to the page.
		if method == http.MethodGet {
			return nil, errs.InvalidArgument("show with POST")
		}
		t, err := a.pageResolve(ctx, caller, space, in.Tool)
		if err != nil {
			return nil, err
		}
		open := map[string]any{"op": "open", "tool": t.ID, "title": in.Title}
		if in.Microtool != "" {
			open["microtool"] = in.Microtool
		}
		if len(in.Args) > 0 {
			open["args"] = in.Args
		}
		for _, k := range []string{"x", "y", "w", "h"} {
			if v, ok := in.Rect[k].(float64); ok {
				open[k] = v
			}
		}
		room := "home"
		if !p.RoomID.IsZero() {
			room = p.RoomID.String()
		}
		var out struct {
			IDs []string `json:"ids"`
		}
		if err := a.pageDispatch(ctx, caller, "spaces", "desktop_update", map[string]any{"space": space, "room": room, "ops": []any{open}}, &out); err != nil {
			return nil, err
		}
		window := ""
		if len(out.IDs) > 0 {
			window = out.IDs[0]
		}
		return map[string]any{"ok": true, "window": window}, nil
	}
	return nil, errs.NotFound("no page api " + op + "; use context, tools, microtools, call, agents, ask, frontend or show")
}

// pageOpenUIKit serves the embedded OpenUI kit for App UIs.
func pageOpenUIKit(method, name string) (*network.Response, error) {
	if method != http.MethodGet && method != http.MethodHead {
		return nil, errs.InvalidArgument("kit assets are GET only")
	}
	name = path.Clean("/" + name)
	name = strings.TrimPrefix(name, "/")
	if name == "" || name == "." {
		name = "README.md"
	}
	data, err := asemanopenui.File(name)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, errs.NotFound("no such OpenUI kit file")
		}
		return nil, errs.Wrap(errs.CodeInternal, err, "openui kit")
	}
	ctype := "application/octet-stream"
	switch {
	case strings.HasSuffix(name, ".js"):
		ctype = "text/javascript; charset=utf-8"
	case strings.HasSuffix(name, ".css"):
		ctype = "text/css; charset=utf-8"
	case strings.HasSuffix(name, ".md"):
		ctype = "text/markdown; charset=utf-8"
	case strings.HasSuffix(name, ".json"):
		ctype = "application/json; charset=utf-8"
	case strings.HasSuffix(name, ".html"):
		ctype = "text/html; charset=utf-8"
	}
	body := data
	if method == http.MethodHead {
		body = nil
	}
	return &network.Response{Status: http.StatusOK, Body: body, Header: map[string]string{
		"Content-Type": ctype, "Cache-Control": "public, max-age=300",
	}}, nil
}

// pageAgent is one space agent as an OpenUI page sees it.
type pageAgent struct {
	Name        string `json:"name"`
	ID          string `json:"id"`
	Description string `json:"description,omitempty"`
	Status      string `json:"status,omitempty"`
}

func (a *API) pageAgents(ctx context.Context, caller api.Caller, space string) ([]pageAgent, error) {
	var res struct {
		Bots []struct {
			ID          string `json:"id"`
			Name        string `json:"name"`
			Kind        string `json:"kind"`
			Description string `json:"description"`
			Status      string `json:"status"`
		} `json:"bots"`
	}
	if err := a.pageDispatch(ctx, caller, "spaces", "bots_list", map[string]any{"space": space}, &res); err != nil {
		return nil, err
	}
	out := []pageAgent{}
	for _, b := range res.Bots {
		if b.Kind != string(bot.KindAgent) || b.ID == "" {
			continue
		}
		out = append(out, pageAgent{Name: b.Name, ID: b.ID, Description: b.Description, Status: b.Status})
	}
	return out, nil
}

func (a *API) pageResolveAgent(ctx context.Context, caller api.Caller, space, agent string) (*pageAgent, error) {
	agent = strings.TrimSpace(agent)
	if agent == "" {
		return nil, errs.InvalidArgument("name the agent")
	}
	agents, err := a.pageAgents(ctx, caller, space)
	if err != nil {
		return nil, err
	}
	for i := range agents {
		if agents[i].ID == agent || strings.EqualFold(agents[i].Name, agent) {
			return &agents[i], nil
		}
	}
	names := make([]string, 0, len(agents))
	for _, ag := range agents {
		names = append(names, ag.Name)
	}
	if len(names) == 0 {
		return nil, errs.NotFound(agent + " is no agent of this space (none installed)")
	}
	return nil, errs.NotFound(agent + " is no agent of this space; its agents: " + strings.Join(names, ", "))
}

// pageTools lists the space's tools (not the agents' built-in ones).
func (a *API) pageTools(ctx context.Context, caller api.Caller, space string) ([]pageTool, error) {
	var res struct {
		Tools []struct {
			Name        string           `json:"name"`
			Description string           `json:"description"`
			BotID       string           `json:"bot_id"`
			Frontend    string           `json:"frontend"`
			Commands    []map[string]any `json:"commands"`
		} `json:"tools"`
	}
	if err := a.pageDispatch(ctx, caller, "spaces", "tools_list", map[string]any{"space": space}, &res); err != nil {
		return nil, err
	}
	out := []pageTool{}
	for _, t := range res.Tools {
		if t.BotID == "" {
			continue
		}
		mt := t.Commands
		if mt == nil {
			mt = []map[string]any{}
		}
		out = append(out, pageTool{Name: t.Name, ID: t.BotID, Description: t.Description, Frontend: t.Frontend, Microtools: mt})
	}
	return out, nil
}

// pageResolve finds a tool of the space by its id or (case-insensitive) name.
func (a *API) pageResolve(ctx context.Context, caller api.Caller, space, tool string) (*pageTool, error) {
	tool = strings.TrimSpace(tool)
	if tool == "" {
		return nil, errs.InvalidArgument("name the tool")
	}
	tools, err := a.pageTools(ctx, caller, space)
	if err != nil {
		return nil, err
	}
	for i := range tools {
		if tools[i].ID == tool || strings.EqualFold(tools[i].Name, tool) {
			return &tools[i], nil
		}
	}
	names := make([]string, 0, len(tools))
	for _, t := range tools {
		names = append(names, t.Name)
	}
	return nil, errs.NotFound(tool + " is no tool of this space; its tools: " + strings.Join(names, ", "))
}

func (a *API) pageDispatch(ctx context.Context, caller api.Caller, ns, action string, body map[string]any, out any) error {
	raw, err := json.Marshal(body)
	if err != nil {
		return err
	}
	dispatch := a.pageActions
	if dispatch == nil {
		dispatch = func(ctx context.Context, ns, action string, req *api.ActionRequest) (*api.ActionResponse, error) {
			req.Origin = a.K.NodeID()
			return a.K.Actions().Dispatch(ctx, ns, action, req)
		}
	}
	resp, err := dispatch(ctx, ns, action, &api.ActionRequest{Caller: caller, Body: raw, Meta: map[string]any{}})
	if err != nil {
		return err
	}
	if resp.Status >= 400 {
		var e struct {
			Error string `json:"error"`
			Code  string `json:"code"`
		}
		_ = json.Unmarshal(resp.Body, &e)
		if e.Error == "" {
			e.Error = http.StatusText(resp.Status)
		}
		code := errs.Code(e.Code)
		if code == "" {
			code = errs.CodeInternal
		}
		return errs.New(code, e.Error)
	}
	return json.Unmarshal(resp.Body, out)
}

// pageToolResult turns a tools.invoke result into App UI data: unwrap MCP
// content / structuredContent (JSON text becomes an object; plain text stays
// a string). Non-MCP payloads pass through unchanged.
func pageToolResult(v any) (any, error) {
	if v == nil {
		return nil, nil
	}
	switch x := v.(type) {
	case string:
		return vmm.ToolResultValue(x)
	default:
		raw, err := json.Marshal(x)
		if err != nil {
			return v, nil
		}
		return vmm.ToolResultValue(string(raw))
	}
}

func first(v []string) string {
	if len(v) == 0 {
		return ""
	}
	return v[0]
}
