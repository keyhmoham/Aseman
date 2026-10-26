package asemanopenui

import (
	"strings"
	"testing"
)

func TestKitAssetsPresent(t *testing.T) {
	for _, name := range []string{"openui.js", "openui.css", "catalog.js", "catalog.spec.json", "README.md", "COMPONENTS.md"} {
		data, err := File(name)
		if err != nil || len(data) == 0 {
			t.Fatalf("%s: %v len=%d", name, err, len(data))
		}
	}
	js, _ := File("openui.js")
	for _, want := range []string{"AsemanOpenUI", "aseman-open-panel", "aseman-open-query", "apiJSON(\"ask\"", "function agents", "ensureCatalog", "paintContent", "catalog.js"} {
		if !strings.Contains(string(js), want) {
			t.Fatalf("openui.js missing %q", want)
		}
	}
	cat, _ := File("catalog.js")
	for _, want := range []string{"AsemanOpenUICatalog", "tryParseOpenUI", "AppShell", "Kanban", "BarChart"} {
		if !strings.Contains(string(cat), want) {
			t.Fatalf("catalog.js missing %q", want)
		}
	}
	spec, _ := File("catalog.spec.json")
	if !strings.Contains(string(spec), `"AppShell"`) || !strings.Contains(string(spec), `"components"`) {
		t.Fatal("catalog.spec.json should list components")
	}
	css, _ := File("openui.css")
	if !strings.Contains(string(css), "--md-sys-color-primary") {
		t.Fatal("openui.css should use Aseman/M3 theme tokens")
	}
	if !strings.Contains(string(css), ".ou-kanban") {
		t.Fatal("openui.css should include catalog component styles")
	}
}

func TestFileRejectsTraversal(t *testing.T) {
	if _, err := File("../openui.go"); err == nil {
		t.Fatal("expected error for traversal")
	}
}
