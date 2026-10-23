package surface

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

// A screen is laid out as an app: its body takes the rest of the window and
// scrolls inside itself, and what grows is in a scrolling region.
func TestInspectChecksTheAppLayout(t *testing.T) {
	page := Inspect([]map[string]any{
		{"id": "root", "component": "Column", "children": []any{"title", "kpis", "chart", "rows", "more"}},
		{"id": "title", "component": "Text", "text": "Orders", "variant": "h4"},
		{"id": "kpis", "component": "Grid", "children": []any{"a", "b"}},
		{"id": "a", "component": "Stat", "label": "Open", "value": 3},
		{"id": "b", "component": "Stat", "label": "Done", "value": 9},
		{"id": "chart", "component": "Chart", "type": "line", "data": []any{}, "x": "t", "y": "v", "height": 900},
		{"id": "rows", "component": "Table", "data": []any{}, "columns": []any{}},
		{"id": "more", "component": "Card", "weight": 1, "child": "note"},
		{"id": "note", "component": "Text", "text": "Notes"},
	})
	for _, want := range []struct{ severity, where, text string }{
		{Blocking, "rows", "in no scrolling region"},
		{Blocking, "more", "does not scroll inside it"},
		{Advice, "chart", "taller than a phone"},
	} {
		if !has(page.Issues, want.severity, want.where, want.text) {
			t.Errorf("missing %s issue on %s (%q); got %v", want.severity, want.where, want.text, page.Issues)
		}
	}
	unweighted := Inspect([]map[string]any{
		{"id": "root", "component": "Column", "children": []any{"title", "rows"}},
		{"id": "title", "component": "Text", "text": "Orders"},
		{"id": "rows", "component": "Scroll", "child": "table"},
		{"id": "table", "component": "Table", "data": []any{}, "columns": []any{}},
	})
	if !has(unweighted.Issues, Blocking, "root", "nothing in the root takes the rest") {
		t.Errorf("a root with no body passed: %v", unweighted.Issues)
	}
	app := Inspect([]map[string]any{
		{"id": "root", "component": "Column", "children": []any{"title", "split"}},
		{"id": "title", "component": "Text", "text": "Traders", "variant": "h4"},
		{"id": "split", "component": "Split", "weight": 1, "panes": []any{
			map[string]any{"title": "Traders", "child": "table"},
			map[string]any{"title": "Details", "child": "details"},
		}},
		{"id": "table", "component": "Table", "data": map[string]any{"path": "/rows"}, "columns": []any{map[string]any{"field": "name"}}},
		{"id": "details", "component": "Markdown", "text": "Pick a trader"},
		{"id": "compact", "component": "Stat", "label": "Traders", "value": 3},
	})
	for _, i := range app.Issues {
		if i.Severity == Blocking || i.Area == "layout" {
			t.Errorf("an app screen was faulted: %v", i)
		}
	}
	small := Inspect([]map[string]any{{"id": "root", "component": "Text", "text": "Saved"}})
	for _, i := range small.Issues {
		if i.Area == "layout" {
			t.Errorf("a one-line screen needs no scrolling body: %v", i)
		}
	}
}

func TestInspectFlagsTextHeavyScreens(t *testing.T) {
	prose := Inspect([]map[string]any{
		{"id": "root", "component": "Column", "children": []any{"title", "body"}},
		{"id": "title", "component": "Text", "text": "Report", "variant": "h4"},
		{"id": "body", "component": "Scroll", "weight": 1, "child": "col"},
		{"id": "col", "component": "Column", "children": []any{"a", "b", "c", "d"}},
		{"id": "a", "component": "Markdown", "text": "Long intro"},
		{"id": "b", "component": "Text", "text": "Paragraph one", "variant": "body"},
		{"id": "c", "component": "Text", "text": "Paragraph two", "variant": "body"},
		{"id": "d", "component": "Callout", "text": "More notes", "severity": "info"},
	})
	if !has(prose.Issues, Advice, "root", "mostly text") {
		t.Errorf("expected advice on a text-heavy screen; got %v", prose.Issues)
	}
	chartOnly := Inspect([]map[string]any{
		{"id": "root", "component": "Column", "children": []any{"title", "body"}},
		{"id": "title", "component": "Text", "text": "Sales", "variant": "h4"},
		{"id": "body", "component": "Scroll", "weight": 1, "child": "col"},
		{"id": "col", "component": "Column", "children": []any{"chart", "table"}},
		{"id": "chart", "component": "Chart", "type": "line", "data": []any{}, "x": "t", "y": "v", "height": 260},
		{"id": "table", "component": "Table", "data": []any{}, "columns": []any{map[string]any{"field": "name"}}},
		{"id": "compact", "component": "Stat", "label": "Total", "value": 1},
	})
	if !has(chartOnly.Issues, Advice, "root", "no KPI Stat") {
		t.Errorf("expected advice when charts lack a Stat strip; got %v", chartOnly.Issues)
	}
	balanced := Inspect([]map[string]any{
		{"id": "root", "component": "Column", "children": []any{"title", "body"}},
		{"id": "title", "component": "Text", "text": "Sales", "variant": "h4"},
		{"id": "body", "component": "Scroll", "weight": 1, "child": "col"},
		{"id": "col", "component": "Column", "children": []any{"kpis", "chart"}},
		{"id": "kpis", "component": "Grid", "minColumnWidth": 160, "children": []any{"s1", "s2"}},
		{"id": "s1", "component": "Stat", "label": "Revenue", "value": 12},
		{"id": "s2", "component": "Stat", "label": "Orders", "value": 3},
		{"id": "chart", "component": "Chart", "type": "area", "data": []any{}, "x": "t", "y": "v", "height": 260},
		{"id": "compact", "component": "Stat", "label": "Revenue", "value": 12},
	})
	for _, i := range balanced.Issues {
		if i.Area == "design" && strings.Contains(i.Problem, "text") {
			t.Errorf("a balanced viz screen was faulted: %v", i)
		}
		if i.Area == "design" && strings.Contains(i.Problem, "KPI") {
			t.Errorf("a screen with Stats was faulted for missing KPIs: %v", i)
		}
	}
}
