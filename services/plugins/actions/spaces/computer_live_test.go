package spaces

import (
	"strings"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/spaces/models/proxy"
)

func TestComputerStateNamesWhatPeopleSee(t *testing.T) {
	cases := []struct {
		status any
		op     string
		want   string
	}{
		{"unprovisioned", "", "none"},
		{bot.StatusRunning, "", "awake"},
		{bot.StatusStopped, "", "asleep"},
		{bot.StatusPaused, "", "asleep"},
		{bot.StatusCreating, "", "starting"},
		{bot.StatusFailed, "", "failed"},
		// What someone asked for shows while it runs, whatever the record says.
		{bot.StatusStopped, "waking", "waking"},
		{bot.StatusRunning, "sleeping", "sleeping"},
	}
	for _, c := range cases {
		if got := computerState(c.status, c.op); got != c.want {
			t.Errorf("computerState(%v, %q) = %q, want %q", c.status, c.op, got, c.want)
		}
	}
}

func TestComputerBusyWakesWatchersAndClears(t *testing.T) {
	s := &Service{}
	sp, _ := identity.Parse("0123456789abcdef0123456789abcdef")
	changed := s.computerWait()
	done := s.computerBusy(sp, "waking")
	select {
	case <-changed:
	case <-time.After(time.Second):
		t.Fatal("starting an operation did not wake the watchers")
	}
	if op := s.computerOp(sp); op != "waking" {
		t.Fatalf("op = %q", op)
	}
	changed = s.computerWait()
	done()
	select {
	case <-changed:
	case <-time.After(time.Second):
		t.Fatal("finishing an operation did not wake the watchers")
	}
	if op := s.computerOp(sp); op != "" {
		t.Fatalf("op after done = %q", op)
	}
}

func TestDeskComputerWindow(t *testing.T) {
	d := Desktop{Viewport: DeskViewport{W: 1600, H: 900}}
	now := time.Now()
	id, err := d.Apply(DeskOp{Op: "open", Kind: DeskComputer, Tool: "x", Args: map[string]any{"password": "leak"}}, "ann", now)
	if err != nil {
		t.Fatal(err)
	}
	w := d.window(id)
	if w.Tool != DeskComputerTool || w.Frontend != DeskComputerFrontend || len(w.Args) != 0 || w.Title != "Computer" {
		t.Fatalf("computer window = %+v", w)
	}
	again, err := d.Apply(DeskOp{Op: "open", Kind: DeskComputer}, "ann", now)
	if err != nil || again != id || len(d.Windows) != 1 {
		t.Fatalf("reopen = %q, %v, %d windows", again, err, len(d.Windows))
	}
	if s := d.Summary(); !strings.Contains(s, "computer") {
		t.Fatalf("summary = %s", s)
	}
}

func TestDesktopViewerPage(t *testing.T) {
	for _, ok := range []string{"tradera-view.html", "v2.html"} {
		if !desktopViewerPage(ok) {
			t.Errorf("rejected %q", ok)
		}
	}
	for _, bad := range []string{"", "../x.html", "a/b.html", "x.js", "X.html", "https://e.com/x.html"} {
		if desktopViewerPage(bad) {
			t.Errorf("accepted %q", bad)
		}
	}
	if !strings.Contains(string(desktopScript), `echo "DESKTOP_VIEWER:$VIEWER_PAGE"`) {
		t.Fatal("the desktop program does not name its viewer")
	}
}

func TestProxyKinds(t *testing.T) {
	cases := map[string]proxy.Proxy{
		"desktop": {Port: desktopPort, Title: desktopTitle},
		"tool":    {Port: 23001, Title: toolPrefix + "Weather"},
		"preview": {Port: 3000, Title: "Last Stand"},
	}
	for want, p := range cases {
		if got := proxyKind(&p); got != want {
			t.Errorf("%+v: %s, want %s", p, got, want)
		}
	}
	// A site someone serves on 6080 under another name is still a preview.
	if got := proxyKind(&proxy.Proxy{Port: desktopPort, Title: "My app"}); got != "preview" {
		t.Errorf("6080 app = %s", got)
	}
}
