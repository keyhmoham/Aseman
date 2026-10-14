package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/a2ui"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/tools/models"
	"github.com/tradera/tradera/plugins/actions/usage/models/usage"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// A tool's frontend is what people use it through.
//
// A static frontend is an Elpian miniapp: a program the device runs on the
// Elpian VM (bytecode) or QuickJS (source), calling the tool's microtools
// through tools.invoke.
//
// A generative frontend is A2UI generated from the deployer's skill the first
// time anyone asks for it. The generated Template — A2UI components, the data
// bindings that fill them and the actions their buttons run, all expressed as
// calls of the tool's microtools — is kept in the component registry
// (tool_components). Every later request is served from the registry and
// filled with fresh data by running the bindings for the person asking.

// A2UIVersion and BasicCatalog are what generated surfaces are written in.
const (
	A2UIVersion  = "v0.9"
	BasicCatalog = "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"
)

// Template is a generated frontend.
type Template struct {
	Title string `json:"title,omitempty"`
	// Components are A2UI basic-catalog components; the one with id "root"
	// is the surface's root. Values bound to data use {"path": "/..."}.
	Components []map[string]any `json:"components"`
	// Data fills the data model: each binding calls a microtool and puts its
	// result at a JSON pointer.
	Data []Binding `json:"data,omitempty"`
	// Actions are what the surface's buttons run, by event name.
	Actions map[string]Action `json:"actions,omitempty"`
}

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
	if err := a2ui.Check(t.Components); err != nil {
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

// Messages renders the template, filled with [data], as the A2UI messages
// that create its surface.
func (t *Template) Messages(surfaceID string, data map[string]any) []map[string]any {
	a2ui.Normalize(t.Components) // templates cached before generation normalized
	return []map[string]any{
		{"version": A2UIVersion, "createSurface": map[string]any{"surfaceId": surfaceID, "catalogId": BasicCatalog}},
		{"version": A2UIVersion, "updateComponents": map[string]any{"surfaceId": surfaceID, "components": t.Components}},
		{"version": A2UIVersion, "updateDataModel": map[string]any{"surfaceId": surfaceID, "path": "/", "value": data}},
	}
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
			"title": t.Title, "messages": t.Messages("tool-"+tool.BotID, data), "actions": actionNames(t)})
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
		if in.Regenerate && tool.Owner != req.Caller.ID.String() {
			return nil, errs.Permission("only the tool's owner can regenerate its frontend")
		}
		component, cached, err := s.component(ctx, c, tool, spec, in.Regenerate)
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
		component, _, err := s.component(ctx, c, tool, spec, false)
		if err != nil {
			return nil, err
		}
		t = &Template{}
		if err := json.Unmarshal([]byte(component.Template), t); err != nil {
			return nil, err
		}
	}
	action, ok := t.Actions[in.Action]
	if !ok {
		return nil, errs.NotFound("action " + in.Action)
	}
	data := in.Data
	if data == nil {
		data = map[string]any{}
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
	return helper.JSON(map[string]any{"result": result, "data": data,
		"messages": []map[string]any{{"version": A2UIVersion, "updateDataModel": map[string]any{"surfaceId": "tool-" + tool.BotID, "path": "/", "value": data}}}})
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

// component returns the tool's generated frontend from the registry, or
// generates it (as the caller, who pays for the model) when the registry has
// none for the current skill and microtools.
func (s *Service) component(ctx context.Context, c caller, tool *models.Tool, spec models.FrontendSpec, regenerate bool) (*models.Component, bool, error) {
	commands, err := s.CommandsFor(ctx, tool.BotID, c.Caller.ID.String(), c.Space)
	if err != nil || len(commands) == 0 {
		commands = tool.Commands
	}
	key := componentKey(spec, commands)
	id := s.key("component/" + tool.BotID + "/" + key)
	var row models.Component
	if !regenerate {
		if err := s.R.GetString(ctx, "tool_components", id, &row); err == nil {
			row.Uses++
			row.UpdatedAt = time.Now().UTC()
			_ = s.R.UpdateString(ctx, "tool_components", id, &row)
			return &row, true, nil
		}
	}
	skill, err := s.entity(ctx, tool.BotID, models.EntityFrontendSkill)
	if err != nil {
		return nil, false, err
	}
	t, model, err := s.generate(ctx, c, tool, skill, commands)
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
	return &row, false, nil
}

// --- generation -------------------------------------------------------------------

// generationPrompt teaches the model the Template format and the components
// devices render (a2ui.CatalogPrompt).
var generationPrompt = `You design the user interface of a tool, as A2UI v0.9 components: rich, clean and useful — charts for series, tables for records, stat tiles for headline numbers, laid out in grids and sections.
Reply with ONE JSON object, no prose, of this shape:
{
  "title": "short title",
  "components": [ A2UI components, flat list; the root has "id": "root" ],
  "data": [ {"path": "/pointer", "microtool": "<name>", "args": {...}} ],
  "actions": { "<event name>": {"microtool": "<name>", "args": {...}, "result": "/pointer", "reload": true} }
}
` + a2ui.CatalogPrompt + `
Rules: every value shown from the tool comes from the data model, filled by "data" bindings that call the tool's microtools (only those listed, with arguments matching their schemas); buttons (and tappable views' "action") send events that "actions" map to microtools. In action args, {"$context": "key"} takes the event context's value and {"$data": "/pointer"} the data model's. Bind inputs under /form. Repeat rows (days, hours, results) with a List, a Table or a Chart over an array, never numbered paths. Pick the view that fits the data: a Chart for values over time or categories, a Table for records with several fields, Stat tiles for the few numbers that matter most. No invented data.`

// generate asks the node's default model for a frontend, and bills the
// tokens to the caller.
func (s *Service) generate(ctx context.Context, c caller, tool *models.Tool, skill string, commands []map[string]any) (*Template, string, error) {
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
	microtools := map[string]bool{}
	var list strings.Builder
	for _, cmd := range commands {
		name, _ := cmd["name"].(string)
		if name == "" {
			continue
		}
		microtools[name] = true
		schema, _ := json.Marshal(cmd["schema"])
		list.WriteString("- " + name + ": " + strings.TrimSpace(asString(cmd["description"])) + "\n  arguments: " + string(schema) + "\n")
	}
	user := "Tool: " + rec.Name + "\n\nWhat the deployer wants (skill):\n" + skill + "\n\nMicrotools:\n" + list.String()
	var t Template
	var tokensIn, tokensOut int64
	var lastErr error
	messages := []map[string]any{{"role": "system", "content": generationPrompt}, {"role": "user", "content": user}}
	for attempt := 0; attempt < 3; attempt++ {
		content, in, out, err := s.complete(ctx, provider, messages)
		tokensIn, tokensOut = tokensIn+in, tokensOut+out
		if err != nil {
			lastErr = err
			break
		}
		t, lastErr = parseTemplate(content)
		if lastErr == nil {
			lastErr = t.validate(microtools)
		}
		if lastErr == nil {
			break
		}
		// Repair rounds: the model is told what was wrong.
		messages = append(messages, map[string]any{"role": "assistant", "content": content},
			map[string]any{"role": "user", "content": "That is not valid: " + lastErr.Error() +
				". Reply with the corrected JSON object only: {\"title\", \"components\": [flat list, each {\"id\", \"component\", ...props}, children as ids, one with id \"root\"], \"data\", \"actions\"}."})
	}
	s.billGeneration(ctx, c, rec.ID, tokensIn, tokensOut)
	if lastErr != nil {
		return nil, "", errs.New(errs.CodeUnavailable, "could not generate the frontend: "+lastErr.Error())
	}
	return &t, provider.Model, nil
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
		raw["components"] = a2ui.Flatten(c)
	}
	b, _ := json.Marshal(raw)
	var t Template
	if err := json.Unmarshal(b, &t); err != nil {
		return Template{}, err
	}
	a2ui.Normalize(t.Components)
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
	body, _ := json.Marshal(map[string]any{"model": provider.Model, "messages": messages, "temperature": 0.2,
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
