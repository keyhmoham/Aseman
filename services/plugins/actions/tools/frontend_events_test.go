package tools

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/tools/models"
)

// Models write a button's action in the shorthand devices fire
// ({"name", "context"}), with the microtool inline on it: the template takes
// it as the event's entry in "actions", so the button works.
func TestInlineActionsAreAdopted(t *testing.T) {
	tpl, err := parseTemplate(`{"components": [
		{"id": "root", "component": "Column", "children": ["q", "go"]},
		{"id": "q", "component": "TextField", "label": "Search", "value": {"path": "/form/query"}},
		{"id": "go", "component": "Button", "child": "go_text",
		 "action": {"name": "search_hub", "microtool": "hub_search", "args": {"query": {"$data": "/form/query"}}, "result": "/results"}},
		{"id": "go_text", "component": "Text", "text": "Search"}]}`)
	if err != nil {
		t.Fatal(err)
	}
	want := Action{Microtool: "hub_search", Args: map[string]any{"query": map[string]any{"$data": "/form/query"}}, Result: "/results"}
	if got := tpl.Actions["search_hub"]; !reflect.DeepEqual(got, want) {
		t.Fatalf("search_hub: %+v, want %+v", got, want)
	}
	if err := tpl.checkEvents(); err != nil {
		t.Fatal(err)
	}
	// A desk window's template passed back with an action is read the same way.
	raw, _ := json.Marshal(map[string]any{"components": tpl.Components})
	var window map[string]any
	_ = json.Unmarshal(raw, &window)
	w, err := windowTemplate(window)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := w.Actions["search_hub"]; !ok {
		t.Fatal("the window's template lost the action")
	}
}

// Events no entry maps are found wherever a component sends them: the
// shorthand, a Menu item's, an Elpian node's.
func TestCheckEventsSeesEveryEvent(t *testing.T) {
	tpl := Template{Components: []map[string]any{
		{"id": "root", "component": "Column", "children": []any{"a", "m"}},
		{"id": "a", "component": "Button", "action": map[string]any{"name": "refresh"}},
		{"id": "m", "component": "Menu", "items": []any{
			map[string]any{"label": "Delete", "action": map[string]any{"event": map[string]any{"name": "delete"}}},
			map[string]any{"label": "Copy", "action": map[string]any{"functionCall": map[string]any{"call": "copyToClipboard"}}},
		}},
	}, Actions: map[string]Action{"refresh": {Microtool: "list"}}}
	err := tpl.checkEvents()
	if err == nil || !strings.Contains(err.Error(), "events delete ") {
		t.Fatalf("got %v, want the Menu item's event reported", err)
	}
}

// An event no entry maps, named after one of the tool's microtools, runs it
// with the arguments its schema takes from the form and the event.
func TestAnEventNamedAfterAMicrotoolRunsIt(t *testing.T) {
	person := identity.ID{Node: 1, Entity: 2}
	s := &Service{commandCache: map[string]cachedCommands{"bot/" + person.String() + "/space": {at: time.Now(), rows: []map[string]any{
		{"name": "search_hub", "schema": map[string]any{"properties": map[string]any{"query": map[string]any{}, "limit": map[string]any{}}}},
	}}}}
	c := caller{Caller: api.Caller{ID: person}, Space: "space"}
	tool := &models.Tool{BotID: "bot"}
	data := map[string]any{"form": map[string]any{"query": "coder", "draft": "x"}, "results": []any{}}
	got, ok := s.namedAction(context.Background(), c, tool, "search_hub", map[string]any{"limit": 5.0}, data)
	want := Action{Microtool: "search_hub", Args: map[string]any{"query": "coder", "limit": 5.0}, Reload: true}
	if !ok || !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v (%v), want %+v", got, ok, want)
	}
	if _, ok := s.namedAction(context.Background(), c, tool, "nothing", nil, data); ok {
		t.Fatal("an event named after no microtool has no action")
	}
}
