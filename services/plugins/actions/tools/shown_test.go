package tools

import (
	"reflect"
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

func TestAutoSpecStandsInForMissingGenerativeFrontends(t *testing.T) {
	generative := models.FrontendSpec{Mode: models.FrontendGenerative, Version: "v7"}
	static := models.FrontendSpec{Mode: models.FrontendStatic, Runtime: "quickjs"}
	if got := autoSpec(generative, true); got != generative {
		t.Fatalf("a generative frontend is served as it is: %+v", got)
	}
	for _, spec := range []models.FrontendSpec{static, {}} {
		got := autoSpec(spec, true)
		if got.Mode != models.FrontendGenerative || !isAuto(got) {
			t.Fatalf("auto for %+v: %+v", spec, got)
		}
		if autoSpec(spec, false) != spec {
			t.Fatal("without auto, the tool's own frontend")
		}
	}
	// Its own registry entry, apart from any skill's.
	if componentKey(autoSpec(static, true), nil) == componentKey(generative, nil) {
		t.Fatal("auto frontends share a registry key with a skill's")
	}
}
