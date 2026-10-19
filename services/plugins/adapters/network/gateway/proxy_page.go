package apihttp

// A web page an agent builds is served from the space's sandbox through a
// preview gateway (/v1/proxy/{id}/). Under its own prefix the gateway also
// answers two things itself, never forwarded to the sandbox:
//
//   - _tradera/kit/<file>: Tradera's web UI kit (pkg/webkit), the app's look
//     and components for web pages, so "/_tradera/kit/tradera-ui.js" works
//     whatever the page's base path;
//   - _tradera/api/<op>: the page's client for the Tradera API. It calls the
//     space's tools' microtools as the person viewing the page, in the
//     preview's space, the way a frontend calls its backend:
//     context, tools, microtools {tool} and call {tool, microtool, args}.
//
// Both are authorized like the rest of the preview: the person's session
// (the preview cookie after the first load) and membership of its space;
// requests that change something come from the preview's own page only.

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/webkit"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/spaces/models/proxy"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
)

// pagePrefix is the part of a preview's path the gateway answers itself.
const pagePrefix = "_tradera/"

// webkitServe serves the kit's files at /v1/webkit/{file}, for pages served
// from anywhere (they hold no data, so no sign-in is needed).
func (a *API) webkitServe(ctx context.Context, req *network.Request) (*network.Response, error) {
	params := map[string]string{}
	if raw := req.Header["x-route-params"]; raw != "" {
		_ = json.Unmarshal([]byte(raw), &params)
	}
	return kitFile(params["file"])
}

func kitFile(name string) (*network.Response, error) {
	body, ctype, ok := webkit.File(name)
	if !ok {
		return nil, errs.NotFound("no kit file " + name)
	}
	return &network.Response{Status: http.StatusOK, Body: body, Header: map[string]string{
		"Content-Type":                ctype,
		"Cache-Control":               "public, max-age=300",
		"Access-Control-Allow-Origin": "*",
	}}, nil
}

// proxyPage answers a preview's _tradera/ request (rest is the path after
// the prefix) for [acc], a member of the preview's space.
func (a *API) proxyPage(ctx context.Context, req *network.Request, p *proxy.Proxy, acc *account.Account, method, rest string) (*network.Response, error) {
	if file, ok := strings.CutPrefix(rest, "kit/"); ok {
		return kitFile(file)
	}
	op, ok := strings.CutPrefix(rest, "api/")
	if !ok {
		return nil, errs.NotFound("no such page route")
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
		// frontend / action: a tool's generative frontend and its actions.
		Action   string         `json:"action"`
		Context  map[string]any `json:"context"`
		Data     map[string]any `json:"data"`
		Template map[string]any `json:"template"`
		// show: the desk window's title, rectangle and phone look.
		Title   string         `json:"title"`
		Request string         `json:"request"`
		Rect    map[string]any `json:"rect"`
	}
	if method != http.MethodGet && len(req.Body) > 0 {
		if err := json.Unmarshal(req.Body, &in); err != nil {
			return nil, errs.InvalidArgument("the request body must be a JSON object")
		}
	} else {
		in.Tool, in.Microtool = first(req.Query["tool"]), first(req.Query["microtool"])
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
		}
		if !p.RoomID.IsZero() {
			out["room"] = p.RoomID.String()
		}
		return out, nil
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
		return map[string]any{"tool": t.Name, "microtool": in.Microtool, "result": res.Result}, nil
	case "frontend", "action":
		// The tool's own frontend for the page to render (a generative one
		// is A2UI, the same surface the app shows), and its actions.
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
		if in.Template != nil {
			body["template"] = in.Template
		}
		if in.Request != "" {
			body["request"] = in.Request
		}
		name := "frontend_get"
		if op == "action" {
			if method == http.MethodGet || in.Action == "" {
				return nil, errs.InvalidArgument(`action needs POST {"tool", "action", "context", "data"}`)
			}
			name = "frontend_action"
			body["action"], body["context"], body["data"] = in.Action, orEmpty(in.Context), orEmpty(in.Data)
		}
		var out map[string]any
		if err := a.pageDispatch(ctx, caller, "tools", name, body, &out); err != nil {
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
		open := map[string]any{"op": "open", "tool": t.ID, "title": in.Title, "request": in.Request}
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
	return nil, errs.NotFound("no page api " + op + "; use context, tools, microtools, call, frontend, action or show")
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

func orEmpty(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

func first(v []string) string {
	if len(v) == 0 {
		return ""
	}
	return v[0]
}
