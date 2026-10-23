package surface

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestCheck(t *testing.T) {
	ok := []map[string]any{
		{"id": "root", "type": "Column", "children": []any{"c"}},
		{"id": "c", "component": "Chart", "type": "line"},
	}
	if err := Check(ok); err != nil {
		t.Fatal(err)
	}
	// Legacy "component" alone is accepted and normalized to "type".
	legacy := []map[string]any{{"id": "root", "component": "Text", "text": "Hi"}}
	if err := Check(legacy); err != nil {
		t.Fatal(err)
	}
	if legacy[0]["type"] != "Text" {
		t.Fatalf("expected normalize to type: %v", legacy[0])
	}
	for name, bad := range map[string][]map[string]any{
		"no root":   {{"id": "a", "type": "Text"}},
		"no type":   {{"id": "root"}},
		"invented":  {{"id": "root", "type": "Column"}, {"id": "x", "type": "BarGraph"}},
		"no pieces": nil,
	} {
		if err := Check(bad); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	err := Check([]map[string]any{{"id": "root", "type": "Sparkles"}})
	if err == nil || !strings.Contains(err.Error(), "Sparkles") || !strings.Contains(err.Error(), "Table") {
		t.Fatalf("the error names the component and what to use instead: %v", err)
	}
}

// Components() is self-consistent; Flutter agui catalog sources exist (full
// Dart sync lands as the app catalog grows to match).
func TestComponentsMatchTheApp(t *testing.T) {
	for _, c := range Components() {
		if !Known(c) {
			t.Errorf("Components entry %q not Known", c)
		}
	}
	dir := filepath.Join("..", "..", "..", "app", "lib", "src", "agui", "catalog")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Skip("app agui catalog not here:", err)
	}
	var dartFiles int
	spec := regexp.MustCompile(`(?:asemanItem|_kit|_container)\(\s*'([A-Za-z0-9]+)'`)
	app := map[string]bool{}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".dart") {
			continue
		}
		dartFiles++
		src, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		for _, m := range spec.FindAllStringSubmatch(string(src), -1) {
			app[m[1]] = true
		}
	}
	if dartFiles == 0 {
		t.Fatalf("no dart files under %s", dir)
	}
	// Every name declared in the Flutter catalog must be in Components().
	for name := range app {
		if !Known(name) {
			t.Errorf("Flutter catalog has %q but surface.Components does not", name)
		}
	}
	for _, c := range aseman {
		if c == "ToolFrontend" || c == "Elpian" {
			continue
		}
		if !strings.Contains(CatalogPrompt, c+" {") && !strings.Contains(CatalogPrompt, c+" ") {
			// New chrome/forms may be listed on shared lines; require a mention.
			if !strings.Contains(CatalogPrompt, c) {
				t.Errorf("CatalogPrompt does not teach %s", c)
			}
		}
	}
	if CatalogID == "" || !strings.Contains(CatalogID, "agui/catalogs") {
		t.Fatalf("CatalogID: %s", CatalogID)
	}
}

// DesignPrompt is the product-designer skill every generator and reviewer
// shares: visualization-first application screens, not documents.
func TestDesignPromptIsVisualizationFirst(t *testing.T) {
	for _, want := range []string{
		"senior product designer",
		"Visualization",
		"KPI",
		"Stat",
		"Chart",
		"App layout",
		"360",
		"1400",
		"Anti-patterns",
		"AG-UI",
		"chat",
	} {
		if !strings.Contains(DesignPrompt, want) {
			t.Errorf("DesignPrompt missing %q", want)
		}
	}
	if !strings.Contains(CatalogPrompt, DesignPrompt) {
		t.Error("CatalogPrompt must include DesignPrompt")
	}
}
