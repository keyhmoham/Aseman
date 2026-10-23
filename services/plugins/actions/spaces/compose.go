package spaces

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/agui"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/surface"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// composeInput is an agent's ui_compose call.
type composeInput struct {
	Title      string           `json:"title"`
	Components []map[string]any `json:"components"`
	Data       []struct {
		Path      string         `json:"path"`
		Tool      string         `json:"tool"`
		Microtool string         `json:"microtool"`
		Args      map[string]any `json:"args"`
	} `json:"data"`
	Room string   `json:"room"`
	X    *float64 `json:"x"`
	Y    *float64 `json:"y"`
	W    *float64 `json:"w"`
	H    *float64 `json:"h"`
	// Compact: the widget's look on the phone board.
	Compact *DeskCompact `json:"compact"`
}

// maxComposedComponents bounds one composed widget.
const maxComposedComponents = 200

// composeUI implements the ui_compose agent tool: an agent puts together a
// widget from AG-UI Surface components, data its microtool calls return, and the
// frontends of the space's tools (ToolFrontend components), and opens it as
// a card window on the room's desk (the same title again refreshes that
// window). Every call and every embedded tool is checked to
// belong to the space; the data is fetched now, in the agent's scope, so the
// widget shows what was true when it was made, and embedded frontends fetch
// their own data for whoever opens them.
func (s *Service) composeUI(ctx context.Context, spaceID, roomID identity.ID, agentName, argsJSON string) (string, error) {
	var in composeInput
	var review []surface.Issue
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument("ui_compose arguments must be a JSON object")
	}
	if len(in.Components) == 0 || len(in.Components) > maxComposedComponents {
		return "", errs.InvalidArgument("ui_compose needs 1..200 components")
	}
	list := make([]any, len(in.Components))
	for i, c := range in.Components {
		list[i] = c
	}
	in.Components = surface.Flatten(list)
	surface.Normalize(in.Components)
	tools, err := s.SpaceTools(ctx, spaceID, identity.ID{})
	if err != nil {
		return "", err
	}
	inSpace := map[string]vmm.Tool{}
	for _, t := range tools {
		if t.BotID != "" {
			inSpace[t.BotID] = t
		}
	}
	if err := surface.Check(in.Components); err != nil {
		return "", err
	}
	for _, c := range in.Components {
		id, _ := c["id"].(string)
		kind, _ := c["component"].(string)
		if kind == "ToolFrontend" {
			tool, _ := c["tool"].(string)
			t, ok := inSpace[tool]
			if !ok {
				return "", errs.InvalidArgument("ToolFrontend " + id + " names no tool of this space")
			}
			if t.Frontend == "" {
				return "", errs.InvalidArgument(t.Name + " has no frontend to embed; show its data instead")
			}
			c["frontend"] = t.Frontend
			c["name"] = t.Name
		}
	}
	data := map[string]any{}
	var failed []string
	var sources []surface.Source
	for _, b := range in.Data {
		if !strings.HasPrefix(b.Path, "/") || b.Microtool == "" {
			return "", errs.InvalidArgument("each data binding needs a path (/...) and a microtool")
		}
		botID, err := identity.Parse(b.Tool)
		if _, ok := inSpace[b.Tool]; err != nil || !ok {
			return "", errs.InvalidArgument("data binding " + b.Path + " names no tool of this space")
		}
		payload := b.Args
		if payload == nil {
			payload = map[string]any{}
		}
		body, _ := json.Marshal(map[string]any{"function": b.Microtool, "payload": payload})
		reply, err := s.AskBot(ctx, spaceID, botID, string(body), nil, nil)
		var value any
		if err == nil {
			value, err = vmm.ToolResultValue(reply)
		}
		src := surface.Source{Path: b.Path, From: b.Microtool, Live: true}
		if err != nil {
			failed = append(failed, b.Path+": "+err.Error())
			value = map[string]any{"error": err.Error()}
			src.Err = err.Error()
		}
		sources = append(sources, src)
		setDataPointer(data, b.Path, value)
	}
	// The widget is reviewed as it was filled before anyone is shown it: what
	// is broken comes back to the agent to fix, and only a widget that works
	// opens.
	if issues := reviewComposed(in.Components, data, sources, failed); blocking(issues) > 0 {
		return "", errs.InvalidArgument(composeReport(issues))
	} else if len(issues) > 0 {
		review = issues
	}
	surfaceID := "ui-" + strings.ReplaceAll(strings.ToLower(agentName), " ", "-")
	body, _ := json.Marshal(map[string]any{
		"title": in.Title,
		// AG-UI events: create/update/patch + state snapshot for the desk.
		"messages": agui.EventsToMaps(agui.SurfaceEvents(surfaceID, in.Components, data, map[string]any{"layout": "app"})),
	})
	target, err := deskRoom(roomID, in.Room)
	if err != nil {
		return "", err
	}
	title := strings.TrimSpace(in.Title)
	if title == "" {
		title = "Widget"
	}
	var widget map[string]any
	_ = json.Unmarshal(body, &widget)
	d, ids, err := s.UpdateDesk(ctx, spaceID, target, agentName, []DeskOp{{
		Op: "open", Kind: DeskComposed, Title: title, Widget: widget,
		X: in.X, Y: in.Y, W: in.W, H: in.H, Compact: in.Compact,
	}})
	if err != nil {
		return "", err
	}
	out := map[string]any{"ok": true, "window": windowJSON(d, ids[0]), "data_paths": len(in.Data), "desk": d.Summary()}
	if len(review) > 0 {
		out["review"] = review
	}
	raw, _ := json.Marshal(out)
	return string(raw), nil
}

func setDataPointer(model map[string]any, path string, value any) {
	parts := strings.Split(strings.TrimPrefix(path, "/"), "/")
	node := model
	for i, p := range parts {
		p = strings.ReplaceAll(strings.ReplaceAll(p, "~1", "/"), "~0", "~")
		if i == len(parts)-1 {
			node[p] = value
			return
		}
		next, ok := node[p].(map[string]any)
		if !ok {
			next = map[string]any{}
			node[p] = next
		}
		node = next
	}
}

// reviewComposed inspects a composed widget filled with [data]: its tree,
// what every component shows against what the bindings really returned, and
// its controls (a composed widget sends no events: interaction is
// client-side or an embedded ToolFrontend's).
func reviewComposed(components []map[string]any, data map[string]any, sources []surface.Source, failed []string) []surface.Issue {
	inspected := surface.Inspect(components)
	issues := append([]surface.Issue{}, inspected.Issues...)
	for _, f := range failed {
		issues = append(issues, surface.Issue{Severity: surface.Blocking, Area: "data", Where: "data " + strings.SplitN(f, ": ", 2)[0],
			Problem: "the microtool failed when the widget was filled: " + f, Fix: "call it with arguments its schema accepts, or leave it out"})
	}
	for _, e := range inspected.Events {
		issues = append(issues, surface.Issue{Severity: surface.Blocking, Area: "interaction", Where: e.Component,
			Problem: "sends the event " + e.Name + ", but a composed widget sends no events, so it does nothing",
			Fix:     "use a client-side functionCall (setValue, toggle…), a selection, or embed the tool's frontend (ToolFrontend)"})
	}
	return append(issues, inspected.CheckData(data, sources)...)
}

func blocking(issues []surface.Issue) int {
	n := 0
	for _, i := range issues {
		if i.Severity == surface.Blocking {
			n++
		}
	}
	return n
}

// composeReport is the review the agent gets back, to fix the widget and
// compose it again.
func composeReport(issues []surface.Issue) string {
	var b strings.Builder
	b.WriteString("the widget was filled and checked before opening, and it does not work yet; nothing was opened. Fix these and call ui_compose again:")
	for _, i := range issues {
		b.WriteString("\n- " + i.Severity + " " + i.String())
	}
	return b.String()
}

// presentInput is an agent's ui_present call: show a Surface Spec UI in chat,
// on the desk, or both.
type presentInput struct {
	Title      string           `json:"title"`
	Components []map[string]any `json:"components"`
	Data       map[string]any   `json:"data"`
	// Placement: chat | desk | both (default chat).
	Placement string `json:"placement"`
	// Layout hint: chat | app.
	Layout  string       `json:"layout"`
	Room    string       `json:"room"`
	X       *float64     `json:"x"`
	Y       *float64     `json:"y"`
	W       *float64     `json:"w"`
	H       *float64     `json:"h"`
	Compact *DeskCompact `json:"compact"`
}

// presentUI implements ui_present: AG-UI Surface Spec in chat and/or desk.
func (s *Service) presentUI(ctx context.Context, spaceID, roomID identity.ID, agentName, argsJSON string) (string, error) {
	var in presentInput
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument("ui_present arguments must be a JSON object")
	}
	if len(in.Components) == 0 || len(in.Components) > maxComposedComponents {
		return "", errs.InvalidArgument("ui_present needs 1..200 components")
	}
	list := make([]any, len(in.Components))
	for i, c := range in.Components {
		list[i] = c
	}
	in.Components = surface.Flatten(list)
	surface.Normalize(in.Components)
	if err := surface.Check(in.Components); err != nil {
		return "", errs.InvalidArgument("ui_present: " + err.Error())
	}
	placement := strings.ToLower(strings.TrimSpace(in.Placement))
	if placement == "" {
		placement = "chat"
	}
	if placement != "chat" && placement != "desk" && placement != "both" {
		return "", errs.InvalidArgument("placement must be chat, desk, or both")
	}
	layout := in.Layout
	if layout == "" {
		if placement == "desk" {
			layout = "app"
		} else {
			layout = "chat"
		}
	}
	data := in.Data
	if data == nil {
		data = map[string]any{}
	}
	surfaceID := "present-" + strings.ReplaceAll(strings.ToLower(agentName), " ", "-")
	events := agui.EventsToMaps(agui.SurfaceEvents(surfaceID, in.Components, data, map[string]any{"layout": layout}))
	title := strings.TrimSpace(in.Title)
	if title == "" {
		title = "UI"
	}
	out := map[string]any{"ok": true, "placement": placement, "title": title}
	target, err := deskRoom(roomID, in.Room)
	if err != nil {
		return "", err
	}
	if placement == "chat" || placement == "both" {
		sender := identity.ID{}
		if policy := vmm.ExecutionFrom(ctx); policy.AgentID != "" {
			if agentID, err := identity.Parse(policy.AgentID); err == nil {
				if rec, err := s.Bots.GetBot(ctx, agentID); err == nil {
					sender = rec.AccountID
				}
			}
		}
		if sender.IsZero() {
			return "", errs.InvalidArgument("ui_present chat placement needs an agent sender")
		}
		body, _ := json.Marshal(map[string]any{"title": title, "messages": events, "layout": layout})
		if err := s.postMessage(ctx, spaceID, target, sender, string(body), message.KindAgui); err != nil {
			return "", err
		}
		out["chat"] = true
	}
	if placement == "desk" || placement == "both" {
		widget := map[string]any{"title": title, "messages": events}
		d, ids, err := s.UpdateDesk(ctx, spaceID, target, agentName, []DeskOp{{
			Op: "open", Kind: DeskComposed, Title: title, Widget: widget,
			X: in.X, Y: in.Y, W: in.W, H: in.H, Compact: in.Compact,
		}})
		if err != nil {
			return "", err
		}
		out["window"] = windowJSON(d, ids[0])
		out["desk"] = d.Summary()
	}
	raw, _ := json.Marshal(out)
	return string(raw), nil
}
