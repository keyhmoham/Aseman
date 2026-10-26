package spaces

import (
	"encoding/json"
	"strings"
	"testing"

	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func TestOpenCodeBuiltinApp(t *testing.T) {
	app := openCodeBuiltinApp()
	if app.Name != "opencode" {
		t.Fatalf("name=%q", app.Name)
	}
	if len(app.Commands) < 4 {
		t.Fatalf("expected microtools run/status/models/build, got %d", len(app.Commands))
	}
	names := map[string]bool{}
	for _, c := range app.Commands {
		names[c.Name] = true
	}
	for _, want := range []string{"run", "status", "models", "build"} {
		if !names[want] {
			t.Fatalf("missing command %s", want)
		}
	}
	if !strings.Contains(app.Description, "appui_create") {
		t.Fatal("description should point agents at appui_create")
	}
}

func TestAppUIBuiltinsPresent(t *testing.T) {
	want := map[string]bool{
		"ui_present": false, "appui_create": false, "opencode_run": false,
		"opencode_status": false, "opencode_models": false,
	}
	for _, tool := range vmm.Builtins() {
		if _, ok := want[tool.Name]; ok {
			want[tool.Name] = true
			var args map[string]any
			if err := json.Unmarshal([]byte(tool.Example), &args); err != nil {
				t.Fatalf("%s example: %v", tool.Name, err)
			}
		}
		if tool.Name == "desk_open" {
			t.Fatal("desk_open must not remain after OpenUI removal")
		}
	}
	for name, ok := range want {
		if !ok {
			t.Fatalf("missing builtin %s", name)
		}
	}
}

func TestNewAppUIID(t *testing.T) {
	a, b := newAppUIID(), newAppUIID()
	if len(a) < 8 || a == b {
		t.Fatalf("ids=%q %q", a, b)
	}
}

func TestParseAppuiReadyJSON(t *testing.T) {
	doc := `{"ok":true,"tested":true,"title":"Desk Demo","port":8791,"start":"node server.js","summary":"ok"}`
	ready, ok := parseAppuiReadyJSON(doc)
	if !ok || ready.Title != "Desk Demo" || ready.Port != 8791 {
		t.Fatalf("direct parse: ok=%v %#v", ok, ready)
	}
	trace := "exit=0 aseman-appui: scaffolding\nok\nstate: ready\n" + doc + "\n"
	ready, ok = parseAppuiReadyJSON(trace)
	if !ok || ready.Start != "node server.js" {
		t.Fatalf("stdout parse: ok=%v %#v", ok, ready)
	}
	if _, ok := parseAppuiReadyJSON(`{"ok":true,"tested":false,"start":"x"}`); ok {
		t.Fatal("untested READY must be rejected")
	}
}

func TestAppuiPortFor(t *testing.T) {
	a, b := appuiPortFor("aaa"), appuiPortFor("bbb")
	if a < appuiDefaultPort || a >= appuiDefaultPort+200 {
		t.Fatalf("port out of range: %d", a)
	}
	if a == b {
		t.Fatalf("expected distinct ports for distinct ids, both %d", a)
	}
	if appuiPortFor("aaa") != a {
		t.Fatal("port must be stable for the same id")
	}
}

func TestOpenCodeAsemanConfig(t *testing.T) {
	raw, err := openCodeAsemanConfig("http://aseman:8080/deepagents/v1/llm", "aseman/default")
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	if doc["model"] != "aseman/default" {
		t.Fatalf("model=%v", doc["model"])
	}
	provider, _ := doc["provider"].(map[string]any)
	aseman, _ := provider["aseman"].(map[string]any)
	opts, _ := aseman["options"].(map[string]any)
	if opts["baseURL"] != "http://aseman:8080/deepagents/v1/llm" {
		t.Fatalf("baseURL=%v", opts["baseURL"])
	}
	if opts["apiKey"] != "{env:ASEMAN_LLM_API_KEY}" {
		t.Fatalf("apiKey=%v", opts["apiKey"])
	}
}
