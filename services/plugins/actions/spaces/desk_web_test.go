package spaces

import (
	"strings"
	"testing"
	"time"
)

func TestDeskWebPageWindows(t *testing.T) {
	d := Desktop{Viewport: DeskViewport{W: 1600, H: 900}}
	now := time.Now()
	page := "/v1/proxy/" + strings.Repeat("ab", 16) + "/dashboard?tab=1"
	id, err := d.Apply(DeskOp{Op: "open", Kind: DeskWeb, Tool: "bot-wx", Name: "Weather", Microtool: "ignored", Args: map[string]any{"page": page, "extra": 1}}, "ann", now)
	if err != nil {
		t.Fatal(err)
	}
	w := d.window(id)
	if w.Frontend != DeskWebFrontend || w.Page() != page || len(w.Args) != 1 || w.Microtool != "" || w.Tool != "bot-wx" {
		t.Fatalf("web window %+v", w)
	}
	// The same page again is the same window, brought to the front.
	again, err := d.Apply(DeskOp{Op: "open", Kind: DeskWeb, Tool: "bot-wx", Args: map[string]any{"page": page}}, "ann", now)
	if err != nil || again != id || len(d.Windows) != 1 {
		t.Fatalf("reopen: %s %v %d", again, err, len(d.Windows))
	}
	// A page of no tool shares the pages entry of the dock.
	other, err := d.Apply(DeskOp{Op: "open", Kind: DeskWeb, Args: map[string]any{"page": "/v1/proxy/" + strings.Repeat("cd", 16) + "/"}}, "ann", now)
	if err != nil || d.window(other).Tool != DeskWebTool {
		t.Fatalf("toolless page: %v %+v", err, d.window(other))
	}
	if !strings.Contains(d.Summary(), "web page "+page) {
		t.Fatalf("summary: %s", d.Summary())
	}
	for _, bad := range []string{"https://evil.example/", "/v1/proxy/short/", "/v1/proxy/" + strings.Repeat("zz", 16) + "/", "/v1/proxy/" + strings.Repeat("ab", 16) + "/../../v1/admin", ""} {
		if _, err := d.Apply(DeskOp{Op: "open", Kind: DeskWeb, Args: map[string]any{"page": bad}}, "ann", now); err == nil {
			t.Errorf("accepted page %q", bad)
		}
	}
	if _, err := d.Apply(DeskOp{Op: "pin", ID: id}, "ann", now); err != nil || d.Pins[0].Kind != DeskWeb || d.Pins[0].Args["page"] != page {
		t.Fatalf("pin: %v %+v", err, d.Pins)
	}
}

func TestWebShowInputPage(t *testing.T) {
	id := strings.Repeat("ab", 16)
	cases := map[webShowInput]string{
		{Page: "/v1/proxy/" + id + "/"}:                         "/v1/proxy/" + id + "/",
		{Page: "http://localhost:8080/v1/proxy/" + id + "/x"}:   "/v1/proxy/" + id + "/x",
		{Proxy: id, Path: "/orders"}:                            "/v1/proxy/" + id + "/orders",
		{Page: "/v1/proxy/" + id + "/", Path: "app/index.html"}: "/v1/proxy/" + id + "/app/index.html",
	}
	for in, want := range cases {
		if got := in.page(); got != want {
			t.Errorf("%+v: %s, want %s", in, got, want)
		}
	}
}
