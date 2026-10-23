package tools

import (
	"errors"
	"strings"
	"testing"

	"github.com/aseman/aseman/pkg/surface"
)

var weatherCommands = []map[string]any{
	{"name": "weather_now", "description": "Current weather of a city.", "annotations": map[string]any{"readOnlyHint": true},
		"schema": map[string]any{"properties": map[string]any{"city": map[string]any{"type": "string"}}, "required": []any{"city"}}},
	{"name": "save_city", "description": "Save a favourite city.",
		"schema": map[string]any{"properties": map[string]any{"city": map[string]any{"type": "string"}}, "required": []any{"city"}}},
}

// fakeWeather answers weather_now for known cities, as the tool would.
func fakeWeather(calls *[]string) func(string, map[string]any) (any, error) {
	return func(microtool string, args map[string]any) (any, error) {
		*calls = append(*calls, microtool)
		if microtool != "weather_now" {
			return nil, errors.New("unexpected call of " + microtool)
		}
		if args["city"] == nil || args["city"] == "" {
			return nil, errors.New("city is required")
		}
		return map[string]any{"temperature": 21.5, "condition": "Sunny"}, nil
	}
}

func mustTemplate(t *testing.T, raw string) Template {
	t.Helper()
	tpl, err := parseTemplate(raw)
	if err != nil {
		t.Fatal(err)
	}
	return tpl
}

// A frontend that renders but does not work is found out by filling and
// testing it, and the generator is told exactly what to fix.
func TestReviewFindsWhatDoesNotWork(t *testing.T) {
	var calls []string
	rv := newReviewer("Weather", "Show the weather of a city.", weatherCommands, Shown{}, fakeWeather(&calls))
	tpl := mustTemplate(t, `{"title": "Weather", "components": [
		{"id": "root", "component": "Column", "children": ["temp", "save"]},
		{"id": "temp", "component": "Stat", "label": "Temperature", "value": {"path": "/now/temp"}},
		{"id": "save", "component": "Button", "child": "save_t", "action": {"event": {"name": "save", "context": {"town": "Paris"}}}},
		{"id": "save_t", "component": "Text", "text": "Save"}],
		"data": [{"path": "/now", "microtool": "weather_now", "args": {"city": "Paris", "units": "metric"}}],
		"actions": {"save": {"microtool": "save_city", "args": {"city": {"$context": "city"}}}}}`)
	r := rv.review(&tpl)
	if r.Passed || r.broken == 0 {
		t.Fatalf("a broken frontend passed: %+v", r)
	}
	feedback := r.feedback()
	for _, want := range []string{
		"weather_now takes no argument units",
		`/now has no "temp" (it has: condition, temperature)`,
		`sends save without "city" in its context`,
		"neither shows its result nor reloads",
		"save_city) checked, not run",
		"compact", // deterministic composition gate
	} {
		if !strings.Contains(feedback, want) {
			t.Errorf("feedback lacks %q:\n%s", want, feedback)
		}
	}
	for _, c := range calls {
		if c == "save_city" {
			t.Error("a microtool that changes data was run by the review")
		}
	}
}

// A frontend that works passes, and what was run is said; calls are not
// repeated across rounds.
func TestReviewPassesAWorkingFrontend(t *testing.T) {
	var calls []string
	rv := newReviewer("Weather", "Show the weather of a city.", weatherCommands, Shown{}, fakeWeather(&calls))
	raw := `{"title": "Weather", "components": [
		{"id": "root", "component": "Column", "children": ["title", "body"]},
		{"id": "title", "component": "Text", "text": "Weather", "variant": "h4"},
		{"id": "body", "component": "Scroll", "weight": 1, "children": ["temp", "cond", "city", "go", "fav"]},
		{"id": "compact", "component": "Stat", "label": "Now", "value": {"path": "/now/temperature"}, "format": "number:1"},
		{"id": "temp", "component": "Stat", "label": "Temperature (°C)", "value": {"path": "/now/temperature"}, "format": "number:1"},
		{"id": "cond", "component": "Text", "text": {"path": "/now/condition"}},
		{"id": "city", "component": "TextField", "label": "City", "value": {"path": "/form/city"}},
		{"id": "go", "component": "Button", "child": "go_t", "action": {"event": {"name": "look"}}},
		{"id": "go_t", "component": "Text", "text": "Show"},
		{"id": "fav", "component": "Button", "child": "fav_t", "action": {"event": {"name": "save"}}},
		{"id": "fav_t", "component": "Text", "text": "Save city"}],
		"data": [{"path": "/now", "microtool": "weather_now", "args": {"city": "Paris"}}],
		"actions": {"look": {"microtool": "weather_now", "args": {"city": {"$data": "/form/city"}}, "result": "/now"},
			"save": {"microtool": "save_city", "args": {"city": {"$data": "/form/city"}}, "reload": true}}}`
	tpl := mustTemplate(t, raw)
	r := rv.review(&tpl)
	if !r.Passed {
		t.Fatalf("a working frontend did not pass:\n%s", r.feedback())
	}
	for _, i := range r.Issues {
		if i.Severity == surface.Blocking {
			t.Errorf("blocking: %v", i)
		}
	}
	again := mustTemplate(t, raw)
	rv.review(&again)
	if len(calls) != 1 {
		t.Errorf("weather_now was called %d times for the same arguments", len(calls))
	}
	if !strings.Contains(strings.Join(r.Tested, "\n"), "filled /now from weather_now") {
		t.Errorf("tested: %v", r.Tested)
	}
}

// Of two candidates, the one that works more wins.
func TestReviewWorse(t *testing.T) {
	broken := &Review{broken: 1, Issues: []surface.Issue{{Severity: surface.Blocking}}}
	unclean := &Review{Issues: []surface.Issue{{Severity: surface.Blocking}, {Severity: surface.Advice}}}
	clean := &Review{Issues: []surface.Issue{{Severity: surface.Advice}}}
	if !broken.worse(unclean) || !unclean.worse(clean) || clean.worse(unclean) {
		t.Fatal("candidates ranked wrongly")
	}
}

// A template designed as an app screen tells the device so, and one made
// before does not (it is shown as a page, as it was).
func TestTemplatesSayTheirLayout(t *testing.T) {
	app := Template{Layout: AppLayout, Components: []map[string]any{{"id": "root", "type": "Text", "text": "Hi"}}}
	create := app.Messages("s", nil)[0]
	if create["type"] != "CUSTOM" || create["name"] != "aseman.surface.create" {
		t.Fatalf("expected AG-UI surface create: %v", create)
	}
	value, _ := create["value"].(map[string]any)
	theme, _ := value["theme"].(map[string]any)
	if theme["layout"] != "app" && value["layout"] != "app" {
		t.Fatalf("create layout: %v", create)
	}
	old := Template{Components: app.Components}
	oldCreate := old.Messages("s", nil)[0]
	oldVal, _ := oldCreate["value"].(map[string]any)
	oldTheme, _ := oldVal["theme"].(map[string]any)
	if oldTheme["layout"] == "app" || oldVal["layout"] == "app" {
		t.Fatal("a template made before app layout was marked as one")
	}
}
