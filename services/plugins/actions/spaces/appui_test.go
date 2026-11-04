package spaces

import (
	"encoding/json"
	"os"
	"os/exec"
	"testing"

	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func TestAppUIBuiltinsPresent(t *testing.T) {
	want := map[string]bool{
		"ui_present": false, "appui_create": false, "appui_publish": false, "appui_status": false,
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


// The preview runs an app's start command with sh from /workspace; it must
// start the app as aseman-appui verify did: from its directory, under bash,
// with PORT, HOST and the app's server settings.
func TestAppuiStartCommandRunsTheAppAsVerified(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(dir+"/.aseman", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(appServerEnvFile(dir), []byte("ASEMAN_API_URL=http://node/appapi/v1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	// A bash-only start that names its own dir and reads files relative to it.
	start := `[[ -n "$BASH_VERSION" ]] && echo "$PWD|$PORT|$HOST|$ASEMAN_API_URL" > seen.txt`
	cmd := exec.Command("sh", "-c", appuiStartCommand(dir, 8911, "  "+start+" "))
	cmd.Dir = os.TempDir()
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	seen, err := os.ReadFile(dir + "/seen.txt")
	if err != nil {
		t.Fatal(err)
	}
	if want := dir + "|8911|0.0.0.0|http://node/appapi/v1\n"; string(seen) != want {
		t.Fatalf("seen %q, want %q", seen, want)
	}
}
