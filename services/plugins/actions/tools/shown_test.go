package tools

import (
	"reflect"
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
