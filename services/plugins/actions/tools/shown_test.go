package tools

import (
	"reflect"
	"strings"
	"testing"
)

func TestShownPointsTheBindingsAtOneResult(t *testing.T) {
	tpl := Template{Data: []Binding{
		{Path: "/report", Microtool: "weather_report", Args: map[string]any{"city": "London"}},
		{Path: "/hours", Microtool: "hourly_forecast", Args: map[string]any{"city": "London", "hours": 12}},
		{Path: "/places", Microtool: "search_places", Args: map[string]any{"query": "Lon"}},
	}}
	got := tpl.bindings(Shown{Microtool: "weather_report", Args: map[string]any{"city": "New York", "units": "imperial"}})
	want := []map[string]any{
		{"city": "New York", "units": "imperial"}, // the microtool shown: all its arguments
		{"city": "New York", "hours": 12},         // others: the arguments they share
		{"query": "Lon"},
	}
	for i := range want {
		if !reflect.DeepEqual(got[i].Args, want[i]) {
			t.Errorf("binding %d: %v, want %v", i, got[i].Args, want[i])
		}
	}
	// The template itself is untouched (it is the registry's).
	if tpl.Data[0].Args["city"] != "London" {
		t.Fatal("the template was modified")
	}
	if !reflect.DeepEqual(tpl.bindings(Shown{}), tpl.Data) {
		t.Fatal("no result shown: the template's own bindings")
	}
}

func TestAWindowFrontendIsDesignedForItsRequest(t *testing.T) {
	skill := requestSkill("How hot will it get in Paris this week?", "daily_forecast",
		map[string]any{"city": "Paris"}, `{"days":[{"high":24}]}`)
	for _, want := range []string{
		"How hot will it get in Paris this week?", // the request, in the person's words
		"not a general interface",
		`daily_forecast called with {"city":"Paris"}`, // bound to the very result
		`"high":24`, // designed around its shape
	} {
		if !strings.Contains(skill, want) {
			t.Errorf("design brief lacks %q:\n%s", want, skill)
		}
	}
}

func TestWindowTemplatesAreReadAndChecked(t *testing.T) {
	tpl, err := windowTemplate(map[string]any{
		"title": "Paris this week",
		"components": []any{
			map[string]any{"id": "root", "component": "Text", "text": "High {{/report/high}}"},
		},
		"data": []any{map[string]any{"path": "/report", "microtool": "daily_forecast", "args": map[string]any{"city": "Paris"}}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := tpl.Components[0]["text"].(map[string]any); !ok {
		t.Fatal("placeholders are normalized like any generated frontend")
	}
	if _, err := windowTemplate(map[string]any{"components": []any{}}); err == nil {
		t.Fatal("an empty template is refused")
	}
}
