package tools

import (
	"context"
	"reflect"
	"strings"
	"testing"

	"github.com/tradera/tradera/plugins/actions/tools/models"
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
		map[string]any{"city": "Paris"}, `{"days":[{"high":24}]}`, "")
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

// A frontend generated for each request (cache off) is designed for the
// request while respecting the deployer's skill.
func TestAPerRequestFrontendFollowsTheSkill(t *testing.T) {
	brief := requestSkill("Compare Paris and Rome", "", nil, "", "Always show temperatures in Celsius.")
	for _, want := range []string{"Compare Paris and Rome", "respect it", "Always show temperatures in Celsius."} {
		if !strings.Contains(brief, want) {
			t.Errorf("design brief lacks %q:\n%s", want, brief)
		}
	}
	if strings.Contains(requestSkill("x", "", nil, "", " "), "skill") {
		t.Error("no skill, no skill section")
	}
}

func TestFrontendCacheDefaultsOn(t *testing.T) {
	off := false
	if !(models.FrontendSpec{}).Cached() || (models.FrontendSpec{Cache: &off}).Cached() {
		t.Fatal("cache is on unless turned off")
	}
	spec, _, err := (&Service{}).prepareFrontend(context.Background(), frontendInput{Mode: models.FrontendGenerative, Skill: "s", Cache: &off})
	if err != nil || spec.Cached() {
		t.Fatalf("cache off must be kept: %+v %v", spec, err)
	}
	on := true
	if spec, _, _ = (&Service{}).prepareFrontend(context.Background(), frontendInput{Mode: models.FrontendGenerative, Skill: "s", Cache: &on}); spec.Cache != nil {
		t.Fatal("cache on is the default and not stored")
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

func TestParseTemplateRepairsNestedComponents(t *testing.T) {
	reply := "```json\n" + `{"title":"Painting","components":[{"type":"Column","children":[
		{"type":"Text","text":"Your painting"},
		{"type":"Card","child":{"type":"Image","url":"{/image}"}}]}],
		"data":[{"path":"/","microtool":"export","args":{}}]}` + "\n```"
	tpl, err := parseTemplate(reply)
	if err != nil {
		t.Fatal(err)
	}
	if err := tpl.validate(map[string]bool{"export": true}); err != nil {
		t.Fatalf("%v: %v", err, tpl.Components)
	}
	if len(tpl.Components) != 4 {
		t.Fatalf("%v", tpl.Components)
	}
}
