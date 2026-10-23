package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/agui"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/surface"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/tools/models"
	"github.com/aseman/aseman/plugins/actions/usage/models/usage"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// A tool's frontend is what people use it through.
//
// A static frontend is an Elpian app: a program the device runs on the
// Elpian VM (bytecode) or QuickJS (source), calling the tool's microtools
// through tools.invoke.
//
// A generative frontend is a Fixed Schema Surface Bundle: compiled once from the
// deployer's skill (embedded surface JSON, named archetype, or a bounded LLM
// fallback with a deterministic gate — never an LLM design judge). The Template
// is kept in tool_components and every later request is bind-only: served from
// the registry and filled with fresh data by running the bindings.

// SurfaceSpec is the generative frontend schema version.
const SurfaceSpec = "aseman.surface/v1"

// Template is a generated frontend.
type Template struct {
	Title string `json:"title,omitempty"`
	// Components are AG-UI Surface basic-catalog components; the one with id "root"
	// is the surface's root. Values bound to data use {"path": "/..."}.
	Components []map[string]any `json:"components"`
	// Data fills the data model: each binding calls a microtool and puts its
	// result at a JSON pointer.
	Data []Binding `json:"data,omitempty"`
	// Actions are what the surface's buttons run, by event name.
	Actions map[string]Action `json:"actions,omitempty"`
	// Review is what its review found before it was first served.
	Review *Review `json:"review,omitempty"`
	// Layout is "app" for a template designed as an app screen (it fills
	// its window and its regions scroll inside it, see surface.AppLayout);
	// templates made before are shown as pages that scroll as a whole.
	Layout string `json:"layout,omitempty"`
}

// AppLayout marks a template designed as an app screen.
const AppLayout = "app"

// Binding fills one place of the data model with a microtool's result.
type Binding struct {
	Path      string         `json:"path"`
	Microtool string         `json:"microtool"`
	Args      map[string]any `json:"args,omitempty"`
}

// Action runs a microtool when a button sends its event. Arguments may name
// the event's context ({"$context": "key"}) or the data model ({"$data":
// "/pointer"}). Result puts what it returned in the data model; Reload runs
// the data bindings again afterwards.
type Action struct {
	Microtool string         `json:"microtool"`
	Args      map[string]any `json:"args,omitempty"`
	Result    string         `json:"result,omitempty"`
	Reload    bool           `json:"reload,omitempty"`
}

// validate checks a template is something the device can render and the node
// can run: a root, ids on every component, and microtools the tool has.
func (t *Template) validate(microtools map[string]bool) error {
	if err := surface.Check(t.Components); err != nil {
		return errs.InvalidArgument("the generated frontend: " + err.Error())
	}
	for _, b := range t.Data {
		if !strings.HasPrefix(b.Path, "/") {
			return errs.InvalidArgument("a data binding's path is a JSON pointer")
		}
		if len(microtools) > 0 && !microtools[b.Microtool] {
			return errs.InvalidArgument("the generated frontend calls an unknown microtool " + b.Microtool)
		}
	}
	for name, a := range t.Actions {
		if len(microtools) > 0 && a.Microtool != "" && !microtools[a.Microtool] {
			return errs.InvalidArgument("action " + name + " calls an unknown microtool " + a.Microtool)
		}
	}
	return nil
}

// eventOf is the event an action fires: {"event": {"name", "context"}}, or
// the shorthand {"name", "context"} devices fire too (the app's fireAction).
// A {"functionCall"} runs on the device and fires none.
func eventOf(action map[string]any) map[string]any {
	if event, ok := action["event"].(map[string]any); ok {
		return event
	}
	if _, ok := action["name"].(string); ok && action["functionCall"] == nil {
		return action
	}
	return nil
}

// eachAction calls fn with every action a component holds, at any depth: a
// Button's or a tappable view's "action", a Menu item's, an Elpian node's.
func eachAction(v any, fn func(action map[string]any)) {
	switch x := v.(type) {
	case map[string]any:
		for k, inner := range x {
			if a, ok := inner.(map[string]any); ok && k == "action" {
				fn(a)
			}
			eachAction(inner, fn)
		}
	case []any:
		for _, inner := range x {
			eachAction(inner, fn)
		}
	}
}

// events are the names of the events the template's components send.
func (t *Template) events() []string {
	var names []string
	seen := map[string]bool{}
	for _, c := range t.Components {
		eachAction(c, func(action map[string]any) {
			name, _ := eventOf(action)["name"].(string)
			if name != "" && !seen[name] {
				seen[name] = true
				names = append(names, name)
			}
		})
	}
	return names
}

// adoptInlineActions gives an event that has no entry in Actions the one
// models write inline, on the component's action instead ({"name":
// "search", "microtool": "search_hub", "args": {...}}). Templates already
// generated or kept on a desk are repaired by it as they are read.
func (t *Template) adoptInlineActions() {
	for _, c := range t.Components {
		eachAction(c, func(action map[string]any) {
			event := eventOf(action)
			name, _ := event["name"].(string)
			if name == "" {
				return
			}
			if _, ok := t.Actions[name]; ok {
				return
			}
			for _, spec := range []map[string]any{event, action} {
				microtool, _ := spec["microtool"].(string)
				if microtool == "" {
					continue
				}
				a := Action{Microtool: microtool, Result: asString(spec["result"])}
				a.Args, _ = spec["args"].(map[string]any)
				a.Reload, _ = spec["reload"].(bool)
				if t.Actions == nil {
					t.Actions = map[string]Action{}
				}
				t.Actions[name] = a
				return
			}
		})
	}
}

// checkEvents verifies every event a component sends (a Button's, a
// tappable view's or a Menu item's "action") has an entry in Actions, so no
// generated button is dead. Only generation asks for it: templates already
// served keep working as they are.
func (t *Template) checkEvents() error {
	var missing []string
	for _, name := range t.events() {
		if _, ok := t.Actions[name]; !ok {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return errs.InvalidArgument("events " + strings.Join(missing, ", ") + " are sent by components but have no entry in \"actions\"; " +
			"map each to a microtool (an entry without \"microtool\" does nothing) or remove the button")
	}
	return nil
}

// Messages renders the template, filled with [data], as AG-UI events that
// create its surface (CUSTOM aseman.surface.* + STATE_SNAPSHOT).
func (t *Template) Messages(surfaceID string, data map[string]any) []map[string]any {
	surface.Normalize(t.Components)
	theme := map[string]any{}
	if t.Layout != "" {
		theme["layout"] = t.Layout
	}
	return agui.EventsToMaps(agui.SurfaceEvents(surfaceID, t.Components, data, theme))
}

// --- calling microtools for a frontend --------------------------------------

// caller is who a frontend acts for, and where.
type caller struct {
	Caller api.Caller
	Space  string
	Room   string
}

// call runs one microtool through spaces.ask, exactly as an agent's call: it
// is authorized, metered and billed to the caller, inside its space and room.
func (s *Service) call(ctx context.Context, c caller, botID, microtool string, args map[string]any) (any, error) {
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
	return vmm.ToolResultValue(answer.Reply)
}

// resolveArgs fills an action's arguments from the event's context and the
// data model.
func resolveArgs(args map[string]any, context, data map[string]any) map[string]any {
	out := map[string]any{}
	for k, v := range args {
		if ref, ok := v.(map[string]any); ok && len(ref) == 1 {
			if key, ok := ref["$context"].(string); ok {
				out[k] = context[key]
				continue
			}
			if path, ok := ref["$data"].(string); ok {
				out[k] = getPointer(data, path)
				continue
			}
		}
		out[k] = v
	}
	return out
}

// Shown points a generative frontend at one result: the arguments a
// microtool was called with (by an agent showing what it found, e.g.
// weather_report for {"city": "New York"}). Bindings to that microtool take
// the arguments over their own; every other binding takes those of the
// arguments it already has (the same city for the forecast next to it).
type Shown struct {
	Microtool string         `json:"microtool,omitempty"`
	Args      map[string]any `json:"args,omitempty"`
}

// bindings are the template's data bindings with [shown] applied.
func (t *Template) bindings(shown Shown) []Binding {
	if len(shown.Args) == 0 {
		return t.Data
	}
	out := make([]Binding, len(t.Data))
	for i, b := range t.Data {
		args := map[string]any{}
		for k, v := range b.Args {
			args[k] = v
		}
		for k, v := range shown.Args {
			if _, has := b.Args[k]; has || b.Microtool == shown.Microtool {
				args[k] = v
			}
		}
		b.Args = args
		out[i] = b
	}
	return out
}

// fill runs a template's data bindings for a caller (pointed at [shown]). A
// binding that fails leaves an {"error": ...} at its place rather than
// failing the frontend.
func (s *Service) fill(ctx context.Context, c caller, botID string, t *Template, shown Shown) map[string]any {
	data := map[string]any{}
	for _, b := range t.bindings(shown) {
		v, err := s.call(ctx, c, botID, b.Microtool, b.Args)
		if err != nil {
			v = map[string]any{"error": err.Error()}
		}
		setPointer(data, b.Path, v)
	}
	return data
}

func pointerParts(path string) []string {
	path = strings.TrimPrefix(path, "/")
	if path == "" {
		return nil
	}
	parts := strings.Split(path, "/")
	for i, p := range parts {
		parts[i] = strings.ReplaceAll(strings.ReplaceAll(p, "~1", "/"), "~0", "~")
	}
	return parts
}

func setPointer(model map[string]any, path string, value any) {
	parts := pointerParts(path)
	if len(parts) == 0 {
		if m, ok := value.(map[string]any); ok {
			for k, v := range m {
				model[k] = v
			}
		}
		return
	}
	node := model
	for _, p := range parts[:len(parts)-1] {
		next, ok := node[p].(map[string]any)
		if !ok {
			next = map[string]any{}
			node[p] = next
		}
		node = next
	}
	node[parts[len(parts)-1]] = value
}

func getPointer(model map[string]any, path string) any {
	var node any = model
	for _, p := range pointerParts(path) {
		m, ok := node.(map[string]any)
		if !ok {
			return nil
		}
		node = m[p]
	}
	return node
}

// --- actions ------------------------------------------------------------------

// frontendScope checks a person may use a tool in a space, and returns the
// tool and who the frontend acts for.
func (s *Service) frontendScope(ctx context.Context, req *api.ActionRequest, botID, space, room string) (*models.Tool, caller, error) {
	var tool models.Tool
	if err := s.R.GetString(ctx, "tool_registry", botID, &tool); err != nil {
		return nil, caller{}, err
	}
	sp, err := identity.Parse(space)
	if err != nil {
		return nil, caller{}, errs.InvalidArgument("a tool's frontend runs in a space")
	}
	var roomID identity.ID
	if room != "" {
		if roomID, err = identity.Parse(room); err != nil {
			return nil, caller{}, errs.InvalidArgument("invalid room")
		}
	}
	if err := helper.CheckSpaceAccess(ctx, s.R, req.Caller.ID, sp, roomID, false); err != nil {
		return nil, caller{}, err
	}
	rec, err := s.bot(ctx, botID)
	if err != nil {
		return nil, caller{}, err
	}
	if err := helper.CheckSpaceAccess(ctx, s.R, rec.AccountID, sp, identity.ID{}, false); err != nil {
		return nil, caller{}, errs.Permission("add the tool to this space first")
	}
	return &tool, caller{Caller: req.Caller, Space: space, Room: room}, nil
}

// frontendGet implements tools.frontend_get: a static frontend's program, or
// a generative frontend's surface — generated on first use, from the registry
// after that — filled with the caller's data.
func (s *Service) frontendGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireAuthenticated(req); e != nil {
		return nil, e
	}
	var in struct {
		Bot   string `json:"bot"`
		Space string `json:"space"`
		Room  string `json:"room"`
		// Regenerate replaces the registry's generated frontend (its owner only).
		Regenerate bool `json:"regenerate"`
		// Shown fills a generated frontend with one result (see Shown).
		Shown
		// Template is a frontend designed for one request (a desk window's,
		// see GenerateWindowFrontend): filled and served instead of the
		// tool's own.
		Template map[string]any `json:"template"`
		// Request is what the person asked for: a generative frontend that
		// is not cached is designed for it.
		Request string `json:"request"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	tool, c, err := s.frontendScope(ctx, req, in.Bot, in.Space, in.Room)
	if err != nil {
		return nil, err
	}
	if len(in.Template) > 0 {
		t, err := windowTemplate(in.Template)
		if err != nil {
			return nil, err
		}
		data := s.fill(ctx, c, tool.BotID, t, in.Shown)
		return helper.JSON(map[string]any{"bot_id": tool.BotID, "mode": models.FrontendGenerative, "request": true,
			"title": t.Title, "messages": t.Messages("tool-"+tool.BotID, data), "actions": actionNames(t), "review": t.Review})
	}
	var spec models.FrontendSpec
	_ = json.Unmarshal([]byte(tool.Frontend), &spec)
	out := map[string]any{"bot_id": tool.BotID, "mode": spec.Mode, "version": spec.Version}
	switch spec.Mode {
	case models.FrontendStatic:
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
	case models.FrontendGenerative:
		if !spec.Cached() {
			// Generated for this request, every time, and kept by nobody but
			// the device showing it: it passes the template back with its
			// actions and reloads.
			t, err := s.designFor(ctx, c, tool, in.Request, in.Microtool, in.Args)
			if err != nil {
				return nil, err
			}
			raw, _ := json.Marshal(t)
			var template map[string]any
			_ = json.Unmarshal(raw, &template)
			data := s.fill(ctx, c, tool.BotID, t, in.Shown)
			out["cached"], out["title"], out["template"] = false, t.Title, template
			out["messages"] = t.Messages("tool-"+tool.BotID, data)
			out["actions"] = actionNames(t)
			out["review"] = t.Review
			return helper.JSON(out)
		}
		if in.Regenerate && tool.Owner != req.Caller.ID.String() {
			return nil, errs.Permission("only the tool's owner can regenerate its frontend")
		}
		component, cached, err := s.component(ctx, c, tool, spec, in.Regenerate, in.Shown)
		if err != nil {
			return nil, err
		}
		var t Template
		if err := json.Unmarshal([]byte(component.Template), &t); err != nil {
			return nil, err
		}
		data := s.fill(ctx, c, tool.BotID, &t, in.Shown)
		out["component_id"], out["cached"], out["title"] = component.ID, cached, t.Title
		out["messages"] = t.Messages("tool-"+tool.BotID, data)
		out["actions"] = actionNames(&t)
		out["review"] = t.Review
		// Always return the template so frontend_action can run against the
		// same Surface Bundle the person is looking at (registry key churn
		// must not regenerate a different actions map under them).
		out["template"] = templateMap(&t)
	}
	// No frontend: the mode says so (people get one designed for their
	// request on the desk).
	return helper.JSON(out)
}

func actionNames(t *Template) []string {
	names := make([]string, 0, len(t.Actions))
	for name := range t.Actions {
		names = append(names, name)
	}
	return names
}

// frontendAction implements tools.frontend_action: an event from a generated
// frontend's button runs the microtool its template maps it to, and the
// surface's data model comes back updated.
func (s *Service) frontendAction(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireAuthenticated(req); e != nil {
		return nil, e
	}
	var in struct {
		Bot     string         `json:"bot"`
		Space   string         `json:"space"`
		Room    string         `json:"room"`
		Action  string         `json:"action"`
		Context map[string]any `json:"context"`
		Data    map[string]any `json:"data"`
		// Shown: the result the frontend was opened on, kept by reloads.
		Shown
		// Template: the window's own frontend (see frontend_get).
		Template map[string]any `json:"template"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	tool, c, err := s.frontendScope(ctx, req, in.Bot, in.Space, in.Room)
	if err != nil {
		return nil, err
	}
	var t *Template
	if len(in.Template) > 0 {
		if t, err = windowTemplate(in.Template); err != nil {
			return nil, err
		}
	} else {
		var spec models.FrontendSpec
		_ = json.Unmarshal([]byte(tool.Frontend), &spec)
		if spec.Mode != models.FrontendGenerative {
			return nil, errs.InvalidArgument("only a generated frontend has actions")
		}
		if !spec.Cached() {
			return nil, errs.InvalidArgument("this tool's frontend is generated for each request: pass the template frontend_get returned")
		}
		// Never regenerate here: a new Surface Bundle would not match the
		// buttons already on screen (→ "no action … design it again").
		component, err := s.loadComponent(ctx, tool, spec, c)
		if err != nil {
			return nil, err
		}
		t = &Template{}
		if err := json.Unmarshal([]byte(component.Template), t); err != nil {
			return nil, err
		}
		t.adoptInlineActions()
	}
	data := in.Data
	if data == nil {
		data = map[string]any{}
	}
	action, ok := t.Actions[in.Action]
	if !ok {
		// An event its template maps to nothing, named after one of the
		// tool's microtools: it runs that microtool with what the
		// surface holds for it.
		if action, ok = s.namedAction(ctx, c, tool, in.Action, in.Context, data); !ok {
			known := actionNames(t)
			sort.Strings(known)
			msg := "this frontend has no action " + in.Action
			if len(known) > 0 {
				msg += " (known: " + strings.Join(known, ", ") + ")"
			}
			msg += "; open the tool again so its Surface Bundle matches the buttons"
			return nil, errs.NotFound(msg)
		}
	}
	var result any
	if action.Microtool != "" {
		result, err = s.call(ctx, c, tool.BotID, action.Microtool, resolveArgs(action.Args, in.Context, data))
		if err != nil {
			return nil, err
		}
		if action.Result != "" {
			setPointer(data, action.Result, result)
		}
	}
	if action.Reload {
		for k, v := range s.fill(ctx, c, tool.BotID, t, in.Shown) {
			data[k] = v
		}
	}
	sid := "tool-" + tool.BotID
	return helper.JSON(map[string]any{"result": result, "data": data,
		"messages": agui.EventsToMaps([]agui.Event{
			agui.NewCustom(agui.SurfacePatchData, map[string]any{
				"surfaceId": sid, "path": "/", "value": data,
			}),
		})})
}

// namedAction is the action of an event no template entry maps, when the
// event is named after a microtool of the tool: it calls that microtool with
// the arguments its schema takes from the surface's form (/form) and the
// event's context, and shows the frontend's data again.
func (s *Service) namedAction(ctx context.Context, c caller, tool *models.Tool, name string, context, data map[string]any) (Action, bool) {
	commands, err := s.CommandsFor(ctx, tool.BotID, c.Caller.ID.String(), c.Space)
	if err != nil || len(commands) == 0 {
		commands = tool.Commands
	}
	for _, cmd := range commands {
		if cmd["name"] != name {
			continue
		}
		args := map[string]any{}
		form, _ := data["form"].(map[string]any)
		for _, values := range []map[string]any{form, context} {
			for k, v := range values {
				args[k] = v
			}
		}
		schema, _ := cmd["schema"].(map[string]any)
		if properties, ok := schema["properties"].(map[string]any); ok {
			for k := range args {
				if _, takes := properties[k]; !takes {
					delete(args, k)
				}
			}
		}
		return Action{Microtool: name, Args: args, Reload: true}, true
	}
	return Action{}, false
}

// componentsList implements tools.components_list: the generated frontends
// the registry holds for a tool (its owner sees them; agents compose with
// them through ui_compose).
func (s *Service) componentsList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireAuthenticated(req); e != nil {
		return nil, e
	}
	var in struct {
		Bot string `json:"bot"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	if _, err := s.ownedTool(ctx, req, in.Bot); err != nil {
		return nil, err
	}
	var rows []models.Component
	if err := s.R.List(ctx, "tool_components", database.Filter{Equal: map[string]any{"bot_id": in.Bot}, OrderBy: "updated_at", Asc: false}, &rows); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"components": rows})
}

// --- the component registry -----------------------------------------------------

// componentKey identifies what a frontend is generated from: the frontend's
// version (its skill) and the microtools it may call.
func componentKey(spec models.FrontendSpec, commands []map[string]any) string {
	raw, _ := json.Marshal(commands)
	return fingerprint(spec.Version, string(raw))
}

// cachedFixedSchema returns the newest Fixed Schema registry row for the tool
// when the exact component key missed (eager compile vs serve command shape).
func (s *Service) cachedFixedSchema(ctx context.Context, botID, _ string) *models.Component {
	var rows []models.Component
	if err := s.R.List(ctx, "tool_components", database.Filter{
		Equal: map[string]any{"bot_id": botID}, OrderBy: "updated_at", Asc: false,
	}, &rows); err != nil {
		return nil
	}
	for i := range rows {
		if rows[i].Model == "fixed-schema" {
			return &rows[i]
		}
	}
	return nil
}

// templateMap is the Surface Bundle JSON clients pass back on frontend_action.
func templateMap(t *Template) map[string]any {
	if t == nil {
		return nil
	}
	raw, err := json.Marshal(t)
	if err != nil {
		return nil
	}
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	return out
}

// loadComponent reads the tool's Surface Bundle from the registry without
// generating a new one. Used by frontend_action so taps never redesign the UI.
func (s *Service) loadComponent(ctx context.Context, tool *models.Tool, spec models.FrontendSpec, c caller) (*models.Component, error) {
	commands, err := s.CommandsFor(ctx, tool.BotID, c.Caller.ID.String(), c.Space)
	if err != nil || len(commands) == 0 {
		commands = tool.Commands
	}
	key := componentKey(spec, commands)
	id := s.key("component/" + tool.BotID + "/" + key)
	var row models.Component
	if err := s.R.GetString(ctx, "tool_components", id, &row); err == nil {
		return &row, nil
	}
	if cached := s.cachedComponent(ctx, tool.BotID); cached != nil {
		return cached, nil
	}
	return nil, errs.NotFound("this tool has no generated frontend yet; open it once first")
}

// cachedComponent is the newest registry row for the tool (any key/model).
func (s *Service) cachedComponent(ctx context.Context, botID string) *models.Component {
	var rows []models.Component
	if err := s.R.List(ctx, "tool_components", database.Filter{
		Equal: map[string]any{"bot_id": botID}, OrderBy: "updated_at", Asc: false,
	}, &rows); err != nil || len(rows) == 0 {
		return nil
	}
	return &rows[0]
}

// component returns the tool's generated frontend from the registry, or
// generates it (as the caller, who pays for the model) when the registry has
// none for the current skill and microtools.
func (s *Service) component(ctx context.Context, c caller, tool *models.Tool, spec models.FrontendSpec, regenerate bool, shown Shown) (*models.Component, bool, error) {
	commands, err := s.CommandsFor(ctx, tool.BotID, c.Caller.ID.String(), c.Space)
	if err != nil || len(commands) == 0 {
		commands = tool.Commands
	}
	key := componentKey(spec, commands)
	id := s.key("component/" + tool.BotID + "/" + key)
	var row models.Component
	skill, err := s.entity(ctx, tool.BotID, models.EntityFrontendSkill)
	if err != nil {
		return nil, false, err
	}
	if !regenerate {
		if err := s.R.GetString(ctx, "tool_components", id, &row); err == nil {
			row.Uses++
			row.UpdatedAt = time.Now().UTC()
			_ = s.R.UpdateString(ctx, "tool_components", id, &row)
			return &row, true, nil
		}
		// Eager compile fingerprints tool.Commands; serve may see CommandsFor
		// shape differ. Reuse a Fixed Schema row only when the skill still
		// declares Fixed Schema (never for free-form / LLM skills).
		if surface.ParseSkill(skill).HasFixedSchema() {
			if cached := s.cachedFixedSchema(ctx, tool.BotID, key); cached != nil {
				cached.Uses++
				cached.UpdatedAt = time.Now().UTC()
				_ = s.R.UpdateString(ctx, "tool_components", cached.ID, cached)
				return cached, true, nil
			}
		}
		// Free-form skills: prefer any existing bundle over regenerating on
		// a key mismatch (which would desync buttons from actions).
		if cached := s.cachedComponent(ctx, tool.BotID); cached != nil {
			cached.Uses++
			cached.UpdatedAt = time.Now().UTC()
			_ = s.R.UpdateString(ctx, "tool_components", cached.ID, cached)
			return cached, true, nil
		}
	}
	t, model, err := s.generate(ctx, c, tool, skill, commands, shown)
	if err != nil {
		return nil, false, err
	}
	raw, _ := json.Marshal(t)
	now := time.Now().UTC()
	row = models.Component{ID: id, BotID: tool.BotID, Key: key, Template: string(raw), Model: model, Uses: 1, CreatedAt: now, UpdatedAt: now}
	if err := s.R.CreateID(ctx, "tool_components", identity.MustParse(id), &row); errs.CodeOf(err) == errs.CodeAlreadyExists {
		err = s.R.UpdateString(ctx, "tool_components", id, &row)
	} else if err != nil {
		return nil, false, err
	}
	s.pruneStaleComponents(ctx, tool.BotID, id)
	return &row, false, nil
}

// --- generation -------------------------------------------------------------------

// generationPrompt teaches the model the Template format and the components
// devices render (surface.CatalogPrompt). It frames generation as professional
// product design: visualization-first application screens, not documents.
var generationPrompt = `You are a senior product designer. Build this tool's interface as a realistic professional app screen using the Aseman Surface Spec over AG-UI — visualization-first (KPIs, charts, gauges, tables), sparse text, standard app chrome, responsive at ~360×640 and ~1400×900. Each component is a flat list entry with "id" and "type" (not "component").
Reply with ONE JSON object, no prose, of this shape:
{
  "title": "short title",
  "spec": "aseman.surface/v1",
  "layout": "app",
  "components": [ Surface Spec components, flat list; the root has "id": "root" and "type" ],
  "data": [ {"path": "/pointer", "microtool": "<name>", "args": {...}} ],
  "actions": { "<event name>": {"microtool": "<name>", "args": {...}, "result": "/pointer", "reload": true} }
}
` + surface.CatalogPrompt + `
Data & wiring: every value shown comes from the data model, filled by "data" bindings that call the tool's microtools (only those listed, arguments matching their schemas); buttons and tappable views' "action" send events that "actions" map to microtools. In action args, {"$context": "key"} takes the event context and {"$data": "/pointer"} the data model. Bind inputs under /form. Repeat rows with a List, Table or Chart over an array — never numbered paths. No invented data.
Composition: header → 3–5 Stat KPIs in a Grid → hero Chart (or domain viz) → supporting views → evidence Table/List. Prefer graphical components over Text/Markdown whenever the data is numeric, temporal, categorical or tabular.
Fully functional: every event a component sends has an entry in "actions", keyed by exactly the event's name, and every entry is sent by some component. A component's action is only {"event": {"name", "context"}}: microtool, args, result and reload go in the "actions" entry, never on the component. An action runs ONE microtool; to refresh what is shown, put its result where the view reads it ("result") and/or set "reload": true. Inputs a microtool needs reach it through {"$data": "/form/…"} or the event context; required arguments are never left unbound. Every microtool the skill asks for is reachable (binding or action); binding paths match where components read, field names match microtool results. Per-row actions: tappable selection {"selection": {"path": "/selected"}} + detail bound to /selected/… + buttons with context {"path": "/selected/id"} — a Table has no buttons inside rows.
Follow the deployer's skill for what to show and do; the design and layout rules above still hold where the skill is silent or asks for something that would break on a phone or turn the screen into a document.
A deterministic gate (structure, composition, live bindings, actions) reviews what you emit; Blocking findings come back as coded fixes. Prefer archetypes / Fixed Schema in the skill when possible.`

// generate compiles a Surface Bundle for the tool: Fixed Schema or archetype
// from the skill when present; otherwise a bounded LLM fallback with a
// deterministic gate (no design judge). Tokens are billed to the caller.
func (s *Service) generate(ctx context.Context, c caller, tool *models.Tool, skill string, commands []map[string]any, shown Shown) (*Template, string, error) {
	microtools := map[string]bool{}
	for _, cmd := range commands {
		if name, _ := cmd["name"].(string); name != "" {
			microtools[name] = true
		}
	}

	// Fixed Schema / archetype path — no LLM for layout.
	if fixed, err := compileFromSkill(skill, commands); err != nil {
		return nil, "", err
	} else if fixed != nil {
		rec, err := s.bot(ctx, tool.BotID)
		if err != nil {
			return nil, "", err
		}
		rv := s.reviewerFor(ctx, c, tool.BotID, rec.Name, skill, commands, shown)
		review := rv.review(fixed)
		review.Rounds = 1
		fixed.Review, fixed.Layout = review, AppLayout
		if review.broken > 0 {
			return nil, "", errs.New(errs.CodeUnavailable, "skill Fixed Schema failed the gate: "+review.summary(5))
		}
		return fixed, "fixed-schema", nil
	}

	var provider vmm.ProviderConfig
	if err := bridge.Invoke(ctx, s.K, "llm", "ResolveChat", []any{ctx, "", ""}, &provider); err != nil {
		return nil, "", errs.New(errs.CodeUnavailable, "no model is configured to generate frontends: "+err.Error())
	}
	rec, err := s.bot(ctx, tool.BotID)
	if err != nil {
		return nil, "", err
	}
	payer := c.Caller.ID
	if err := bridge.Invoke(ctx, s.K, "bots", "EnsureFunds", []any{ctx, payer, rec.ID}); err != nil {
		return nil, "", err
	}
	var list strings.Builder
	for _, cmd := range commands {
		name, _ := cmd["name"].(string)
		if name == "" {
			continue
		}
		schema, _ := json.Marshal(cmd["schema"])
		list.WriteString("- " + name + ": " + strings.TrimSpace(asString(cmd["description"])) + "\n  arguments: " + string(schema) + "\n")
	}
	user := "Tool: " + rec.Name + "\n\nWhat the deployer wants (skill):\n" + skill + "\n\nMicrotools:\n" + list.String()
	var tokensIn, tokensOut int64
	// No LLM design judge in the repair loop — deterministic gate only.
	rv := s.reviewerFor(ctx, c, tool.BotID, rec.Name, skill, commands, shown)
	var best *Template
	var lastErr error
	var prevFingerprint string
	messages := []map[string]any{{"role": "system", "content": generationPrompt}, {"role": "user", "content": user}}
	for round := 1; round <= reviewRounds; round++ {
		temp := 0.2
		if round > 1 {
			temp = 0 // repair passes are deterministic
		}
		content, in, out, err := s.completeTemp(ctx, provider, messages, temp)
		tokensIn, tokensOut = tokensIn+in, tokensOut+out
		if err != nil {
			lastErr = err
			break
		}
		t, err := parseTemplate(content)
		if err == nil {
			err = t.validate(microtools)
		}
		if err == nil {
			err = t.checkEvents()
		}
		var feedback string
		if err != nil {
			lastErr = err
			feedback = "That is not valid: " + err.Error() +
				". Reply with the corrected JSON object only: {\"title\", \"components\": [flat list, each {\"id\", \"type\", ...props}, children as ids, one with id \"root\"], \"data\", \"actions\"}."
		} else {
			review := rv.review(&t)
			review.Rounds = round
			if best == nil || best.Review.worse(review) {
				t.Review, t.Layout = review, AppLayout
				best = &t
			}
			if review.Passed {
				break
			}
			fp := surface.FingerprintIssues(review.Issues)
			if fp != "" && fp == prevFingerprint {
				lastErr = errs.New(errs.CodeUnavailable, "frontend repair is not converging: "+review.summary(5))
				break
			}
			prevFingerprint = fp
			feedback = review.feedback()
		}
		messages = append(messages, map[string]any{"role": "assistant", "content": content},
			map[string]any{"role": "user", "content": feedback})
	}
	s.billGeneration(ctx, c, rec.ID, tokensIn, tokensOut)
	if best == nil {
		msg := "could not generate the frontend"
		if lastErr != nil {
			msg += ": " + lastErr.Error()
		}
		return nil, "", errs.New(errs.CodeUnavailable, msg)
	}
	if best.Review.broken > 0 {
		return nil, "", errs.New(errs.CodeUnavailable, "could not generate a working frontend: "+best.Review.summary(5))
	}
	return best, provider.Model, nil
}

// parseTemplate reads a template from a model's reply, repairing the shapes
// models get wrong in the component list (inline children, missing ids, the
// type under another key, no root) before it is checked.
func parseTemplate(content string) (Template, error) {
	var raw map[string]any
	if err := json.Unmarshal([]byte(jsonObject(content)), &raw); err != nil {
		return Template{}, err
	}
	return templateOf(raw)
}

// templateOf reads a template from its JSON object, repairing its
// components (see parseTemplate).
func templateOf(raw map[string]any) (Template, error) {
	if raw == nil {
		return Template{}, errs.InvalidArgument("the template is empty")
	}
	if c, ok := raw["components"]; ok {
		raw["components"] = surface.Flatten(c)
	}
	b, _ := json.Marshal(raw)
	var t Template
	if err := json.Unmarshal(b, &t); err != nil {
		return Template{}, err
	}
	surface.Normalize(t.Components)
	t.adoptInlineActions()
	return t, nil
}

func asString(v any) string { s, _ := v.(string); return s }

// jsonObject is the outermost JSON object in a model's reply (models wrap
// JSON in code fences however they are asked).
func jsonObject(text string) string {
	start, end := strings.Index(text, "{"), strings.LastIndex(text, "}")
	if start < 0 || end <= start {
		return text
	}
	return text[start : end+1]
}

// complete runs one chat completion on an OpenAI-compatible provider.
func (s *Service) complete(ctx context.Context, provider vmm.ProviderConfig, messages []map[string]any) (string, int64, int64, error) {
	return s.completeTemp(ctx, provider, messages, 0.2)
}

// completeTemp is complete with an explicit sampling temperature.
func (s *Service) completeTemp(ctx context.Context, provider vmm.ProviderConfig, messages []map[string]any, temperature float64) (string, int64, int64, error) {
	body, _ := json.Marshal(map[string]any{"model": provider.Model, "messages": messages, "temperature": temperature,
		"max_tokens": 6000, "response_format": map[string]any{"type": "json_object"}})
	callCtx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	req, err := http.NewRequestWithContext(callCtx, http.MethodPost, strings.TrimRight(provider.BaseURL, "/")+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", 0, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	if provider.APIKey != "" {
		if strings.Contains(provider.BaseURL, "googleapis.com") && !strings.HasPrefix(provider.APIKey, "ya29.") {
			req.Header.Set("X-Goog-Api-Key", provider.APIKey)
		} else {
			req.Header.Set("Authorization", "Bearer "+provider.APIKey)
		}
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", 0, 0, err
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, 8<<20))
	if err != nil {
		return "", 0, 0, err
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			PromptTokens     int64 `json:"prompt_tokens"`
			CompletionTokens int64 `json:"completion_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", 0, 0, err
	}
	if res.StatusCode >= 300 || len(out.Choices) == 0 {
		return "", out.Usage.PromptTokens, out.Usage.CompletionTokens, errs.New(errs.CodeUnavailable, "the model refused: "+strings.TrimSpace(string(raw[:min(len(raw), 300)])))
	}
	return out.Choices[0].Message.Content, out.Usage.PromptTokens, out.Usage.CompletionTokens, nil
}

// billGeneration charges the caller for the tokens a generation used, as a
// call of the tool.
func (s *Service) billGeneration(ctx context.Context, c caller, botID identity.ID, in, out int64) {
	if in == 0 && out == 0 {
		return
	}
	ctx = vmm.WithInvocationUsage(ctx)
	vmm.AddInvocationUsage(ctx, usage.Delta{TokensIn: in, TokensOut: out})
	uc := usage.UsageCtx{Kind: usage.KindAsk}
	if sp, err := identity.Parse(c.Space); err == nil {
		uc.SpaceID = sp
	}
	if room, err := identity.Parse(c.Room); err == nil {
		uc.RoomID = room
	}
	var delta usage.Delta
	_ = bridge.Invoke(ctx, s.K, "bots", "BillAndRecordUsage", []any{ctx, c.Caller.ID, botID, int64(0), "frontend generation", uc}, &delta)
}
