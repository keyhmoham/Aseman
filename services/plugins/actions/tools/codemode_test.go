package tools

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func TestNormalizeCodeModeJSStripsAsyncAwait(t *testing.T) {
	got := normalizeCodeModeJS(`async () => {
  const spec = await codemode.spec();
  return Object.keys(spec.paths);
}`)
	if strings.Contains(got, "async") || strings.Contains(got, "await") {
		t.Fatalf("still async/await: %q", got)
	}
}

func TestRunCodeModeJSSearch(t *testing.T) {
	spec := map[string]any{
		"openapi": "3.1.0",
		"paths": map[string]any{
			"/apps/weather/weather_report": map[string]any{"post": map[string]any{}},
			"/apps/board/draw":             map[string]any{"post": map[string]any{}},
		},
	}
	out, err := runCodeModeJS(`async () => {
  const spec = await codemode.spec();
  return Object.keys(spec.paths).filter(p => p.includes("weather"));
}`, spec, nil)
	if err != nil {
		t.Fatal(err)
	}
	arr, ok := out.([]any)
	if !ok || len(arr) != 1 || arr[0] != "/apps/weather/weather_report" {
		t.Fatalf("got %#v", out)
	}
}

func TestRunCodeModeJSExecuteRequest(t *testing.T) {
	spec := map[string]any{"paths": map[string]any{}}
	var seen CodeModeRequest
	out, err := runCodeModeJS(`() => {
  return codemode.request({ method: "POST", path: "/apps/weather/weather_report", body: { city: "London" } });
}`, spec, func(opts CodeModeRequest) (any, error) {
		seen = opts
		return map[string]any{"temp": 18}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if seen.Path != "/apps/weather/weather_report" || seen.Method != "POST" {
		t.Fatalf("request = %#v", seen)
	}
	m, _ := out.(map[string]any)
	if m["temp"] != int64(18) && m["temp"] != float64(18) && m["temp"] != 18 {
		t.Fatalf("result = %#v", out)
	}
}

func TestCodeModeOpenAPIFromApps(t *testing.T) {
	apps := []codeModeApp{{
		Slug: "weather", BotID: "bot-wx", Name: "Weather", Description: "Forecasts",
		Commands: []vmm.ToolCommand{{
			Name: "weather_report", Description: "Report for a city",
			Schema: map[string]any{"type": "object", "properties": map[string]any{
				"city": map[string]any{"type": "string"},
			}},
		}},
	}}
	paths := map[string]any{}
	for _, app := range apps {
		codeModeAddAppPaths(paths, app)
	}
	if paths["/apps/weather/weather_report"] == nil {
		t.Fatal("missing app path")
	}
	if !codeModePlatform["file_send"] || !codeModePlatform["desk_state"] {
		t.Fatal("platform tools should be in Code Mode surface")
	}
}

func TestCodeModeRequestPathRouting(t *testing.T) {
	cases := []struct {
		path string
		ok   bool
	}{
		{"/apps/weather/report", true},
		{"/platform/file_send", true},
		{"/timeline/find_entities", true},
		{"/other/x", false},
		{"/apps/only", false},
	}
	for _, c := range cases {
		parts := strings.Split(strings.Trim(c.path, "/"), "/")
		var valid bool
		switch {
		case len(parts) == 3 && parts[0] == "apps":
			valid = true
		case len(parts) == 2 && (parts[0] == "platform" || parts[0] == "timeline"):
			valid = true
		}
		if valid != c.ok {
			t.Fatalf("%s: valid=%v want %v", c.path, valid, c.ok)
		}
	}
}

func TestCodeModeMCPToolsList(t *testing.T) {
	s := &Service{}
	// tools/list does not need space apps.
	out, err := s.CodeModeMCP(context.Background(), "space-1", []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`))
	if err != nil {
		t.Fatal(err)
	}
	var msg map[string]any
	if json.Unmarshal(out, &msg) != nil {
		t.Fatal(string(out))
	}
	result, _ := msg["result"].(map[string]any)
	tools, _ := result["tools"].([]any)
	names := map[string]bool{}
	for _, tool := range tools {
		m, _ := tool.(map[string]any)
		names[str(m["name"])] = true
	}
	if !names["search"] || !names["execute"] {
		t.Fatalf("tools = %v", names)
	}
}

func str(v any) string {
	s, _ := v.(string)
	return s
}
