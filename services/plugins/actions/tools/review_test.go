package tools

import (
	"errors"
	"strings"
	"testing"

	"github.com/aseman/aseman/pkg/a2ui"
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
	looked := false
	rv := newReviewer("Weather", "Show the weather of a city.", weatherCommands, Shown{}, fakeWeather(&calls),
		func(messages []map[string]any) (string, error) {
			looked = true
			if !strings.Contains(messages[1]["content"].(string), "MISSING") {
				t.Error("the design review was not shown the missing value")
			}
			return `{"issues": [{"severity": "blocking", "area": "purpose", "where": "root", "problem": "No way to pick a city.", "fix": "Add a city field."}]}`, nil
		})
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
		"No way to pick a city.",
		"neither shows its result nor reloads",
		"save_city) checked, not run",
	} {
		if !strings.Contains(feedback, want) {
			t.Errorf("feedback lacks %q:\n%s", want, feedback)
		}
	}
	if !looked {
		t.Error("the surface was not looked at")
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
	rv := newReviewer("Weather", "Show the weather of a city.", weatherCommands, Shown{}, fakeWeather(&calls),
		func([]map[string]any) (string, error) { return `{"issues": []}`, nil })
	raw := `{"title": "Weather", "components": [
		{"id": "root", "component": "Column", "children": ["temp", "cond", "city", "go", "fav"]},
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
		if i.Severity == a2ui.Blocking {
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
	broken := &Review{broken: 1, Issues: []a2ui.Issue{{Severity: a2ui.Blocking}}}
	unclean := &Review{Issues: []a2ui.Issue{{Severity: a2ui.Blocking}, {Severity: a2ui.Advice}}}
	clean := &Review{Issues: []a2ui.Issue{{Severity: a2ui.Advice}}}
	if !broken.worse(unclean) || !unclean.worse(clean) || clean.worse(unclean) {
		t.Fatal("candidates ranked wrongly")
	}
}
