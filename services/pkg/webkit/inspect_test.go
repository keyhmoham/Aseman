package webkit

import (
	"regexp"
	"strings"
	"testing"

	"github.com/aseman/aseman/pkg/surface"
)

func hasIssue(issues []surface.Issue, severity, where, text string) bool {
	for _, i := range issues {
		if i.Severity == severity && strings.Contains(i.Where, where) && strings.Contains(i.Problem, text) {
			return true
		}
	}
	return false
}

// Every <t-…> the kit's own gallery uses is one the inspector knows, so a
// page built like it is never told its components do not exist.
func TestKnownTagsCoverTheGallery(t *testing.T) {
	gallery, _, ok := File("gallery.html")
	if !ok {
		t.Fatal("no gallery")
	}
	for _, m := range regexp.MustCompile(`<(t-[a-z0-9-]+)`).FindAllStringSubmatch(string(gallery), -1) {
		if !KnownTag(m[1]) {
			t.Errorf("<%s> is used by the gallery but not known", m[1])
		}
	}
	if len(knownTags) < 80 {
		t.Errorf("only %d kit tags were found", len(knownTags))
	}
	for _, issue := range InspectPage(gallery).Issues {
		if issue.Severity == surface.Blocking && strings.Contains(issue.Problem, "no component of the kit") {
			t.Error(issue)
		}
	}
}

// A broken page is read as the kit runs it: what does not render, does
// nothing or shows nothing is found.
func TestInspectPageFindsWhatIsBroken(t *testing.T) {
	p := InspectPage([]byte(`<!doctype html><html><head><title>Weather</title>
<script src="/_aseman/kit/aseman-ui.js"></script><script src="app.js"></script></head>
<body>
 <t-data call="Weather/forecast" args='{"city": "Oslo"}' into="/fc"></t-data>
 <t-stat label="Now" bind-value="/fc/temp"></t-stat>
 <t-stat label="Wind" bind-value="/wind/speed"></t-stat>
 <t-tabel data='{"path": "/fc/days"}'></t-tabel>
 <t-table data='{"path": "/fc/days"}' columns='[{"field": "day"}, {"field": "high"}]'></t-table>
 <t-text-field label="City"></t-text-field>
 <t-button text="Save"></t-button>
 <t-button text="Alert" action='{"event": {"name": "alert"}}'></t-button>
 <t-button text="Go" call="Weather/forecast" args='{city: "x"}' into="/fc"></t-button>
 <div style="width: 900px; color: #ff0000">Lorem ipsum dolor</div>
</body></html>`))
	for _, want := range []struct{ severity, where, text string }{
		{surface.Blocking, "t-tabel", "no component of the kit"},
		{surface.Blocking, "t-text-field", "reaches nothing"},
		{surface.Blocking, `t-button[text="Save"]`, "does nothing"},
		{surface.Blocking, `t-button[text="Alert"]`, "no Aseman.on(\"alert\""},
		{surface.Blocking, `t-button[text="Go"]`, "not valid JSON"},
		{surface.Blocking, "<head>", "without its stylesheet"},
		{surface.Blocking, "<head>", "no viewport"},
		{surface.Blocking, "div", "placeholder text"},
		{surface.Advice, "div", "hard-codes colors"},
		{surface.Advice, "div", "fixed width of 900px"},
		{surface.Blocking, "<body>", "is not an app screen"},
		{surface.Blocking, "t-table", "in no region that scrolls"},
	} {
		if !hasIssue(p.Issues, want.severity, want.where, want.text) {
			t.Errorf("missing %s issue on %s (%q); got:\n%v", want.severity, want.where, want.text, p.Issues)
		}
	}
	if len(p.Resources) != 1 || p.Resources[0] != "app.js" {
		t.Errorf("resources: %v", p.Resources)
	}
	var loads, buttons int
	for _, c := range p.Calls {
		if c.Tool != "Weather" || c.Microtool != "forecast" {
			t.Errorf("call: %+v", c)
		}
		if c.Load {
			loads++
			if c.Into != "/fc" || c.Args["city"] != "Oslo" {
				t.Errorf("load: %+v", c)
			}
		} else {
			buttons++
		}
	}
	if loads != 1 || buttons != 1 {
		t.Errorf("calls: %+v", p.Calls)
	}
	// What the page shows, tested against what the load really returned.
	data := map[string]any{"fc": map[string]any{"temperature": 3, "days": []any{map[string]any{"day": "Mon", "max": 4}}}}
	issues := surface.CheckReads(p.Reads, p.Writes, p.Aliases, data, []surface.Source{{Path: "/fc", From: "Weather/forecast", Live: true}}, surface.Blocking)
	for _, want := range []struct{ where, text string }{
		{"t-stat[label=\"Now\"]", `has no "temp"`},
		{"t-stat[label=\"Wind\"]", "nothing fills"},
		{"t-table", `has no "high"`},
	} {
		if !hasIssue(issues, surface.Blocking, want.where, want.text) {
			t.Errorf("missing data issue on %s (%q); got:\n%v", want.where, want.text, issues)
		}
	}
}

// A clean page built with the kit passes: forms submit their fields,
// scripts wire their controls and handle their events, lists scope items.
func TestInspectPagePassesACleanPage(t *testing.T) {
	p := InspectPage([]byte(`<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Orders</title>
<link rel="stylesheet" href="/_aseman/kit/aseman-ui.css"><script src="/_aseman/kit/aseman-ui.js"></script></head>
<body class="t-app">
 <t-row><t-text variant="h4" text="Orders" weight="1"></t-text><t-button id="refresh" text="Refresh"></t-button></t-row>
 <t-data call="Orders/list" into="/orders"></t-data>
 <t-split weight="1">
  <t-scroll title="Orders"><t-for each="/orders"><template><t-text bind-text="symbol"></t-text></template></t-for></t-scroll>
  <t-form title="New order" call="Orders/place" into="/placed">
   <t-text-field label="Symbol" name="symbol"></t-text-field>
   <t-button type="submit" text="Place order"></t-button>
   <t-button text="Pick" action='{"event": {"name": "pick"}}'></t-button>
  </t-form>
 </t-split>
 <script>
  document.getElementById('refresh').addEventListener('click', () => Aseman.load('/orders', 'Orders', 'list'));
  Aseman.on('pick', () => Aseman.data.set('/picked', true));
 </script>
</body></html>`))
	for _, i := range p.Issues {
		if i.Severity == surface.Blocking {
			t.Errorf("blocking: %v", i)
		}
	}
	var form *Call
	for i := range p.Calls {
		if p.Calls[i].Microtool == "place" {
			form = &p.Calls[i]
		}
	}
	if form == nil || len(form.Fields) != 1 || form.Fields[0] != "symbol" || form.Into != "/placed" {
		t.Fatalf("form call: %+v", form)
	}
	data := map[string]any{"orders": []any{map[string]any{"symbol": "AAPL"}}}
	for _, i := range surface.CheckReads(p.Reads, p.Writes, p.Aliases, data, []surface.Source{{Path: "/orders", From: "Orders/list", Live: true}}, surface.Blocking) {
		if i.Severity == surface.Blocking {
			t.Errorf("data: %v", i)
		}
	}
}

// A page is an application screen: its body fills the window, a region takes
// the rest of the height and scrolls inside itself, and what grows is in it.
func TestInspectPageChecksTheAppLayout(t *testing.T) {
	head := `<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Orders</title>
<link rel="stylesheet" href="/_aseman/kit/aseman-ui.css"><script src="/_aseman/kit/aseman-ui.js"></script></head>`
	rows := strings.Repeat(`<t-stat label="Open" value="3"></t-stat>`, 6)
	p := InspectPage([]byte(head + `<body class="t-app">
 <t-text variant="h4" text="Orders"></t-text>` + rows + `
 <t-column weight="1"><t-table data='[]' columns='[]'></t-table></t-column>
 <t-row><t-scroll weight="1"></t-scroll><t-scroll weight="1"></t-scroll></t-row>
</body></html>`))
	for _, want := range []struct{ severity, where, text string }{
		{surface.Blocking, "t-column", "does not scroll inside it"},
		{surface.Blocking, "t-table", "in no region that scrolls"},
		{surface.Advice, "t-row", "scrolling panes side by side"},
	} {
		if !hasIssue(p.Issues, want.severity, want.where, want.text) {
			t.Errorf("missing %s issue on %s (%q); got:\n%v", want.severity, want.where, want.text, p.Issues)
		}
	}
	none := InspectPage([]byte(head + `<body class="t-app"><t-text variant="h4" text="Orders"></t-text>` + rows +
		`<t-scroll><t-table data='[]' columns='[]'></t-table></t-scroll></body></html>`))
	if !hasIssue(none.Issues, surface.Blocking, "<body>", "nothing in the body takes the rest") {
		t.Errorf("a body with no region passed: %v", none.Issues)
	}
	app := InspectPage([]byte(head + `<body class="t-app"><t-text variant="h4" text="Orders"></t-text>` + rows +
		`<t-tabs weight="1"><t-table title="Open" data='[]' columns='[]'></t-table><t-text title="Done" text="None yet"></t-text></t-tabs></body></html>`))
	for _, i := range app.Issues {
		if i.Area == "layout" {
			t.Errorf("an app screen was faulted: %v", i)
		}
	}
}
