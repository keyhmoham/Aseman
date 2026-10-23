package webkit

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/aseman/aseman/pkg/surface"
)

// kitJS is the built kit script.
func kitJS(t *testing.T) string {
	t.Helper()
	body, ctype, ok := File("aseman-ui.js")
	if !ok || !strings.Contains(ctype, "javascript") {
		t.Fatalf("no kit script (%q)", ctype)
	}
	return string(body)
}

// The served script is what tools/build.mjs makes from src/ (edit the
// sources, then run it).
func TestKitIsBuiltFromItsSources(t *testing.T) {
	files, err := filepath.Glob("src/*.js")
	if err != nil || len(files) == 0 {
		t.Fatalf("no sources: %v", err)
	}
	sort.Strings(files)
	var parts []string
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		parts = append(parts, "// ==== "+filepath.Base(f)+" ====\n"+string(b))
	}
	if !strings.Contains(kitJS(t), strings.Join(parts, "\n")) {
		t.Fatal("kit/aseman-ui.js is out of date: run node services/pkg/webkit/tools/build.mjs")
	}
}

func TestFile(t *testing.T) {
	for _, name := range []string{"aseman-ui.js", "aseman-ui.css", "gallery.html"} {
		if _, _, ok := File(name); !ok {
			t.Errorf("%s missing", name)
		}
	}
	for _, bad := range []string{"", "../webkit.go", "kit/aseman-ui.js", "nope.js", "/etc/passwd"} {
		if _, _, ok := File(bad); ok {
			t.Errorf("served %q", bad)
		}
	}
}

func kebab(s string) string {
	return strings.ToLower(regexp.MustCompile(`([a-z0-9])([A-Z])`).ReplaceAllString(s, "${1}-${2}"))
}

// definedTags are the <t-*> elements the kit defines.
func definedTags(js string) map[string]bool {
	out := map[string]bool{}
	re := regexp.MustCompile(`(?:define|component|layout)\('([a-z0-9-]+)'`)
	for _, m := range re.FindAllStringSubmatch(js, -1) {
		out["t-"+m[1]] = true
	}
	// Elements defined in loops: for (const n of ['a', 'b']) define(n, …).
	loop := regexp.MustCompile(`for \(const n of \[([^\]]+)\]\)\s*\{?\s*(?:define|component|layout)\(n`)
	for _, m := range loop.FindAllStringSubmatch(js, -1) {
		for _, q := range regexp.MustCompile(`'([a-z0-9-]+)'`).FindAllStringSubmatch(m[1], -1) {
			out["t-"+q[1]] = true
		}
	}
	// The explicit transitions table.
	for _, q := range regexp.MustCompile(`'([a-z-]+-transition)': \[`).FindAllStringSubmatch(js, -1) {
		out["t-"+q[1]] = true
	}
	return out
}

// Every component the node teaches and checks (the Surface Spec catalog)
// has a kit element, and the AG-UI surface renderer maps it.
func TestKitCoversEverySurfaceComponent(t *testing.T) {
	js := kitJS(t)
	tags := definedTags(js)
	for _, c := range surface.Components() {
		tag := "t-" + kebab(c)
		if c == "CheckBox" {
			tag = "t-checkbox"
		}
		if !tags[tag] {
			t.Errorf("no element %s for the Surface Spec component %s", tag, c)
		}
		if !strings.Contains(js, "  "+c+": 't-") && !strings.Contains(js, " "+c+": 't-") {
			t.Errorf("the AG-UI surface renderer does not map %s", c)
		}
	}
}

// Every Elpian widget the app renders (lib/src/elpian/widgets) has an element.
func TestKitCoversEveryElpianWidget(t *testing.T) {
	files, _ := filepath.Glob("../../../app/lib/src/elpian/widgets/elpian_*.dart")
	if len(files) == 0 {
		t.Skip("app sources not here")
	}
	tags := definedTags(kitJS(t))
	for _, f := range files {
		name := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(f), "elpian_"), ".dart")
		tag := "t-" + strings.ReplaceAll(name, "_", "-")
		if !tags[tag] {
			t.Errorf("no element %s for the Elpian widget %s", tag, filepath.Base(f))
		}
	}
}

// Every HTML element the Elpian engine renders (lib/src/elpian/html_widgets)
// is styled like the app; the rest are structural (no look of their own).
func TestKitStylesEveryHTMLWidget(t *testing.T) {
	files, _ := filepath.Glob("../../../app/lib/src/elpian/html_widgets/html_*.dart")
	if len(files) == 0 {
		t.Skip("app sources not here")
	}
	css, _, _ := File("aseman-ui.css")
	structural := map[string]bool{"br": true, "div": true, "span": true, "param": true, "source": true, "track": true, "area": true,
		"map": true, "picture": true, "datalist": true, "optgroup": true, "option": true, "widgets": true, "table_layout": true,
		"embedded_content_io": true, "embedded_content_stub": true, "embedded_content_web": true}
	alias := map[string]string{"semantic_container": "section", "embedded_content": "iframe", "embedded_link_card": "a", "tr": "tr", "data": "data"}
	for _, f := range files {
		name := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(f), "html_"), ".dart")
		if structural[name] {
			continue
		}
		tag := name
		if a, ok := alias[name]; ok {
			tag = a
		}
		if !regexp.MustCompile(`(^|[\s,{}(])` + tag + `([\s,:.\[{>)]|::)`).Match(css) {
			t.Errorf("no style for <%s> (%s)", tag, filepath.Base(f))
		}
	}
}

// The app's own widgets pages are made of have elements too.
func TestKitCoversTheAppWidgets(t *testing.T) {
	tags := definedTags(kitJS(t))
	for _, tag := range []string{"t-panel", "t-panel-header", "t-stat-card", "t-status-tag", "t-mini-tag", "t-segmented-tab-bar",
		"t-avatar", "t-brand", "t-responsive-grid", "t-data-grid", "t-tag", "t-chip", "t-form", "t-form-field", "t-surface",
		"t-data", "t-for", "t-auto-view", "t-tab"} {
		if !tags[tag] {
			t.Errorf("no element %s", tag)
		}
	}
}
