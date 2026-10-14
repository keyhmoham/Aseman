package a2ui

import (
	"reflect"
	"testing"
)

func TestInterpolation(t *testing.T) {
	for in, want := range map[string]string{
		"{{/forecast/current/emoji}} {{ /forecast/current/temperature_text }}": "${/forecast/current/emoji} ${/forecast/current/temperature_text}",
		"Feels like {{forecast.current.feels_like_text}}":                      "Feels like ${forecast/current/feels_like_text}",
		"{{/forecast/days[1]/label}}: {{days[2].range_text}}":                  "${/forecast/days/1/label}: ${days/2/range_text}",
		"a literal {{ not a path! }} stays":                                    "a literal {{ not a path! }} stays",
	} {
		if got := Interpolation(in); got != want {
			t.Errorf("%q → %q, want %q", in, got, want)
		}
	}
}

func TestValue(t *testing.T) {
	format := func(s string) any {
		return map[string]any{"call": "formatString", "args": map[string]any{"value": s}, "returnType": "string"}
	}
	for in, want := range map[string]any{
		"{{/forecast/current/emoji}}":       map[string]any{"path": "/forecast/current/emoji"},
		"${ /report/place/label }":          map[string]any{"path": "/report/place/label"},
		"{{label}}":                         map[string]any{"path": "label"},
		"High {{/today/high}}°":             format("High ${/today/high}°"),
		"${/a} · ${/b}":                     format("${/a} · ${/b}"),
		"Plain text, nothing to fill in":    "Plain text, nothing to fill in",
		"a literal {{ not a path! }} stays": "a literal {{ not a path! }} stays",
	} {
		if got := Value(in); !reflect.DeepEqual(got, want) {
			t.Errorf("%q → %#v, want %#v", in, got, want)
		}
	}
}

func TestNormalizeLeavesStructureAndSpecFormsAlone(t *testing.T) {
	components := []map[string]any{
		{"id": "t", "component": "Text", "text": "Now: {{/a}}", "variant": "h3"},
		{"id": "bound", "component": "Text", "text": map[string]any{"path": "/a"}},
		{"id": "fmt", "component": "Text", "text": map[string]any{"call": "formatString", "args": map[string]any{"value": "{{/x}}°"}}},
		{"id": "list", "component": "List", "children": map[string]any{"componentId": "row", "path": "/days"}},
		{"id": "b", "component": "Button", "child": "l", "action": map[string]any{"event": map[string]any{"name": "go", "context": map[string]any{"city": "{{/form/city}}", "units": "metric"}}}},
	}
	if n := Normalize(components); n != 3 {
		t.Fatalf("rewrote %d, want 3", n)
	}
	if got := components[0]["text"].(map[string]any)["args"].(map[string]any)["value"]; got != "Now: ${/a}" {
		t.Fatal(got)
	}
	if components[0]["variant"] != "h3" || components[0]["id"] != "t" {
		t.Fatal("touched a literal or an id")
	}
	if !reflect.DeepEqual(components[1]["text"], map[string]any{"path": "/a"}) {
		t.Fatal("rewrote a binding")
	}
	if got := components[2]["text"].(map[string]any)["args"].(map[string]any)["value"]; got != "${/x}°" {
		t.Fatalf("formatString argument: %v", got)
	}
	if !reflect.DeepEqual(components[3]["children"], map[string]any{"componentId": "row", "path": "/days"}) {
		t.Fatal("rewrote a List template")
	}
	ctx := components[4]["action"].(map[string]any)["event"].(map[string]any)["context"].(map[string]any)
	if !reflect.DeepEqual(ctx["city"], map[string]any{"path": "/form/city"}) || ctx["units"] != "metric" {
		t.Fatalf("context: %v", ctx)
	}
}
