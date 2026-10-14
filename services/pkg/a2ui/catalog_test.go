package a2ui

import (
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

func TestCheck(t *testing.T) {
	ok := []map[string]any{
		{"id": "root", "component": "Column", "children": []any{"c"}},
		{"id": "c", "component": "Chart", "type": "line"},
	}
	if err := Check(ok); err != nil {
		t.Fatal(err)
	}
	for name, bad := range map[string][]map[string]any{
		"no root":   {{"id": "a", "component": "Text"}},
		"no type":   {{"id": "root"}},
		"invented":  {{"id": "root", "component": "Column"}, {"id": "x", "component": "BarGraph"}},
		"no pieces": nil,
	} {
		if err := Check(bad); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	err := Check([]map[string]any{{"id": "root", "component": "Sparkles"}})
	if err == nil || !strings.Contains(err.Error(), "Sparkles") || !strings.Contains(err.Error(), "Table") {
		t.Fatalf("the error names the component and what to use instead: %v", err)
	}
}

// The node's list is the app's: both catalogs, read from the Dart sources.
func TestComponentsMatchTheApp(t *testing.T) {
	spec := regexp.MustCompile(`(?m)^\s*'([A-Za-z]+)':\s*(?:const )?(?:_spec\(|ComponentSpec\()`)
	var app []string
	for _, f := range []string{
		"../../../app/lib/src/elpian/a2ui/catalog.dart",
		"../../../app/lib/src/features/tools/presentation/a2ui_catalog.dart",
	} {
		src, err := os.ReadFile(f)
		if err != nil {
			t.Skip("app sources not here:", err)
		}
		for _, m := range spec.FindAllStringSubmatch(string(src), -1) {
			app = append(app, m[1])
		}
	}
	node := append(append([]string{}, basic...), tradera...)
	sort.Strings(app)
	sort.Strings(node)
	if strings.Join(app, ",") != strings.Join(node, ",") {
		t.Fatalf("app components\n  %v\nnode components\n  %v", app, node)
	}
	for _, c := range tradera {
		if c != "ToolFrontend" && c != "Elpian" && !strings.Contains(CatalogPrompt, c+" {") {
			t.Errorf("CatalogPrompt does not teach %s", c)
		}
	}
}
