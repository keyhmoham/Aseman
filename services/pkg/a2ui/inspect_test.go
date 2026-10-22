package a2ui

import (
	"strings"
	"testing"
)

func has(issues []Issue, severity, where, text string) bool {
	for _, i := range issues {
		if i.Severity == severity && i.Where == where && strings.Contains(i.Problem, text) {
			return true
		}
	}
	return false
}

// The tree is read as a device renders it: missing references, cycles,
// unplaced components, unbound inputs and dead or unlabelled buttons are
// found.
func TestInspectFindsBrokenStructure(t *testing.T) {
	s := Inspect([]map[string]any{
		{"id": "root", "component": "Column", "children": []any{"title", "ghost", "q", "go", "loop"}},
		{"id": "title", "component": "Text", "text": "Lorem ipsum dolor"},
		{"id": "q", "component": "TextField", "label": "City"},
		{"id": "go", "component": "Button"},
		{"id": "loop", "component": "Card", "child": "inner"},
		{"id": "inner", "component": "Card", "child": "loop"},
		{"id": "stray", "component": "Text", "text": "never shown"},
	})
	for _, want := range []struct{ severity, where, text string }{
		{Blocking, "root", "\"ghost\", which does not exist"},
		{Blocking, "title", "placeholder text"},
		{Blocking, "q", "no \"value\" binding"},
		{Blocking, "go", "no label"},
		{Blocking, "go", "does nothing"},
		{Blocking, "loop", "contains itself"},
		{Advice, "inner", "Card inside a Card"},
		{Advice, "stray", "not placed"},
		{Advice, "compact", "no \"compact\""},
	} {
		if !has(s.Issues, want.severity, want.where, want.text) {
			t.Errorf("missing %s issue on %s (%q); got %v", want.severity, want.where, want.text, s.Issues)
		}
	}
}

// What components show is tested against the data really filled: a field
// the result does not have, a List over an object and a path nothing fills
// are found; inputs, selections and List items are understood.
func TestCheckDataAgainstTheFilledData(t *testing.T) {
	s := Inspect([]map[string]any{
		{"id": "root", "component": "Column", "children": []any{"temp", "days", "table", "detail", "city", "nope"}},
		{"id": "compact", "component": "Stat", "label": "Now", "value": map[string]any{"path": "/weather/temperature"}},
		{"id": "temp", "component": "Stat", "label": "Temperature", "value": map[string]any{"path": "/weather/temp"}},
		{"id": "days", "component": "Column", "children": map[string]any{"componentId": "day", "path": "/weather"}},
		{"id": "day", "component": "Text", "text": map[string]any{"path": "name"}},
		{"id": "table", "component": "Table", "data": map[string]any{"path": "/hours"},
			"columns":   []any{map[string]any{"field": "time"}, map[string]any{"field": "rain"}},
			"selection": map[string]any{"path": "/selected"}},
		{"id": "detail", "component": "Text", "text": map[string]any{"path": "/selected/wind"}},
		{"id": "city", "component": "TextField", "label": "City", "value": map[string]any{"path": "/form/city"}},
		{"id": "nope", "component": "Text", "text": map[string]any{"path": "/forecast/summary"}},
	})
	data := map[string]any{
		"weather": map[string]any{"temperature": 21.5, "wind": 3},
		"hours":   []any{map[string]any{"time": "10:00", "precipitation": 0.2, "speed": 4}},
	}
	issues := s.CheckData(data, []Source{
		{Path: "/weather", From: "weather_now", Live: true},
		{Path: "/hours", From: "hourly", Live: true},
	})
	for _, want := range []struct{ where, text string }{
		{"temp", "has no \"temp\" (it has: temperature, wind)"},
		{"days", "is an object, not a list"},
		{"table", "has no \"rain\""},
		{"detail", "has no \"wind\""},
		{"nope", "which nothing fills"},
	} {
		if !has(issues, Blocking, want.where, want.text) {
			t.Errorf("missing issue on %s (%q); got %v", want.where, want.text, issues)
		}
	}
	for _, i := range issues {
		if i.Where == "compact" || i.Where == "city" {
			t.Errorf("unexpected issue %v", i)
		}
	}
}

// The outline shows what each component displays, resolved.
func TestOutlineShowsTheFilledSurface(t *testing.T) {
	s := Inspect([]map[string]any{
		{"id": "root", "component": "Column", "children": []any{"t", "go", "go_text"}},
		{"id": "t", "component": "Stat", "label": "Temperature", "value": map[string]any{"path": "/w/temp"}},
		{"id": "go", "component": "Button", "child": "go_text", "action": map[string]any{"event": map[string]any{"name": "refresh"}}},
		{"id": "go_text", "component": "Text", "text": "Refresh"},
	})
	out := s.Outline(map[string]any{"w": map[string]any{"temp": 21.5}}, 4000)
	for _, want := range []string{`t Stat label="Temperature" value={/w/temp} → 21.5`, `sends event {"name":"refresh"}`, `go_text Text text="Refresh"`} {
		if !strings.Contains(out, want) {
			t.Errorf("outline lacks %q:\n%s", want, out)
		}
	}
	if len(s.Events) != 1 || s.Events[0].Name != "refresh" {
		t.Errorf("events: %+v", s.Events)
	}
}
