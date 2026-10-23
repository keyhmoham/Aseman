package spaces

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

const brokenPage = `<!doctype html><html><head><title>Weather</title>
<link rel="stylesheet" href="/_aseman/kit/aseman-ui.css"><script src="/_aseman/kit/aseman-ui.js"></script>
<script src="app.js"></script></head>
<body class="t-page">
 <t-data call="Weather/forecast" args='{"city": "Oslo", "units": "metric"}' into="/fc"></t-data>
 <t-stat label="Temperature" bind-value="/fc/temp"></t-stat>
 <t-button text="Save" call="Weather/save_city" args='{"city": "Oslo"}'></t-button>
 <t-button text="Radar" call="Weather/radar"></t-button>
 <t-button text="Rain" call="Rain/now"></t-button>
</body></html>`

const cleanPage = `<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Weather</title>
<link rel="stylesheet" href="/_aseman/kit/aseman-ui.css"><script src="/_aseman/kit/aseman-ui.js"></script>
<script src="app.js"></script></head>
<body class="t-app">
 <t-text variant="h4" text="Weather"></t-text>
 <t-data call="Weather/forecast" args='{"city": "Oslo"}' into="/fc"></t-data>
 <t-scroll weight="1">
  <t-stat label="Temperature (°C)" bind-value="/fc/temperature" format="number:1"></t-stat>
  <t-form call="Weather/save_city" into="/saved">
   <t-text-field label="City" name="city"></t-text-field>
   <t-button type="submit" text="Save city"></t-button>
  </t-form>
 </t-scroll>
</body></html>`

// servePages serves [pages] by path, as a preview's service would.
func servePages(t *testing.T, pages map[string]string) *httptest.Server {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, ok := pages[r.URL.Path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		if strings.HasSuffix(r.URL.Path, ".js") {
			w.Header().Set("Content-Type", "text/javascript")
		} else {
			w.Header().Set("Content-Type", "text/html")
		}
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)
	return server
}

var weatherTool = vmm.Tool{Name: "Weather", BotID: "0000000000000001000000000000beef"}

func weatherCommands(vmm.Tool) map[string]map[string]any {
	city := map[string]any{"properties": map[string]any{"city": map[string]any{"type": "string"}}, "required": []any{"city"}}
	return map[string]map[string]any{
		"forecast":  {"name": "forecast", "schema": city, "annotations": map[string]any{"readOnlyHint": true}},
		"save_city": {"name": "save_city", "schema": city},
	}
}

func testReviewer(server *httptest.Server, calls *[]string) *pageReviewer {
	record := &proxy.Proxy{TargetURL: server.URL}
	return &pageReviewer{
		fetch: func(rest string, maxBody int64) (int, string, []byte, bool, error) {
			return upstreamGet(context.Background(), record, rest, maxBody)
		},
		tools:    []vmm.Tool{weatherTool},
		commands: weatherCommands,
		call: func(_ *pageTool, microtool string, args map[string]any) (any, error) {
			*calls = append(*calls, microtool)
			if args["units"] != nil {
				return nil, errors.New("unknown argument units")
			}
			return map[string]any{"temperature": 3.5, "condition": "Snow"}, nil
		},
	}
}

// A page that does not work is found out: fetched, inspected, its calls
// checked against the space's tools and run, what it shows looked up in what
// came back.
func TestPageReviewFindsWhatDoesNotWork(t *testing.T) {
	var calls []string
	server := servePages(t, map[string]string{"/": brokenPage})
	r := testReviewer(server, &calls).review("/v1/proxy/x/", "/")
	if r.Passed || r.broken == 0 {
		t.Fatalf("a broken page passed: %+v", r)
	}
	report := r.report(false)
	for _, want := range []string{
		"loads app.js, which answers 404",
		"no viewport meta tag",
		"forecast takes no argument units",
		"Weather/forecast failed when the review ran it",
		"Weather has no microtool radar (it has: forecast, save_city)",
		"Rain is no tool of this space",
		"checked Weather/save_city (t-button[text=\"Save\"]), not run: it may change data",
	} {
		if !strings.Contains(report, want) {
			t.Errorf("report lacks %q:\n%s", want, report)
		}
	}
	for _, c := range calls {
		if c == "save_city" {
			t.Error("the review ran a microtool that changes data")
		}
	}
}

// A page that works passes; what it shows is checked against what its
// loads really returned.
func TestPageReviewPassesAWorkingPage(t *testing.T) {
	var calls []string
	server := servePages(t, map[string]string{"/app/": cleanPage, "/app/app.js": "console.log(1)"})
	r := testReviewer(server, &calls).review("/v1/proxy/x/app/", "/app/")
	if !r.Passed || r.broken != 0 {
		t.Fatalf("a working page did not pass:\n%s", r.report(false))
	}
	if len(calls) != 1 || calls[0] != "forecast" {
		t.Errorf("calls: %v", calls)
	}
}

// web_show does not open a page that does not work: the agent gets the
// report, and the desk stays as it was.
func TestWebShowRefusesABrokenPage(t *testing.T) {
	s, ctx := messageToolHarness(t)
	sp, err := s.CreateSpace(ctx, idFromHex(t, "00000000000000010000000000000001"), "pages space", "")
	if err != nil {
		t.Fatal(err)
	}
	server := servePages(t, map[string]string{"/": brokenPage})
	id := identity.ID{Node: 1, Entity: 77}
	if err := s.saveProxy(ctx, &proxy.Proxy{Entity: entity.Entity{ID: id}, SpaceID: sp.ID, Port: 8080, Title: "Weather", TargetURL: server.URL}, true); err != nil {
		t.Fatal(err)
	}
	room := identity.ID{Node: 1, Entity: 9}
	_, err = s.webShowTool(ctx, sp.ID, room, "aseman", `{"page": "/v1/proxy/`+id.String()+`/"}`)
	if err == nil || !strings.Contains(err.Error(), "it was not opened") || !strings.Contains(err.Error(), "no viewport meta tag") {
		t.Fatalf("web_show: %v", err)
	}
	if d, _ := s.Desk(ctx, sp.ID, room); len(d.Windows) != 0 {
		t.Fatalf("windows: %+v", d.Windows)
	}
}
