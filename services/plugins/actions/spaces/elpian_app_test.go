package spaces

import (
	"strings"
	"testing"
	"time"
)

// App UIs are Elpian unless the person asked for web; an existing app keeps
// what it was built with.
func TestAppUIsDefaultToAnElpianFrontend(t *testing.T) {
	cases := []struct{ asked, existing, want string }{
		{"", "", "elpian"},
		{"", "elpian", "elpian"},
		{"", "web", "web"},
		{"web", "", "web"},
		{"Elpian", "web", "elpian"},
	}
	for _, c := range cases {
		got, err := appuiFrontend(c.asked, c.existing)
		if err != nil || got != c.want {
			t.Fatalf("appuiFrontend(%q, %q) = %q, %v; want %q", c.asked, c.existing, got, err, c.want)
		}
	}
	if _, err := appuiFrontend("flutter", ""); err == nil {
		t.Fatal("an unknown frontend was accepted")
	}
}

// An Elpian app is a desk window that carries its program's path; nothing
// that leaves the app is accepted.
func TestElpianAppWindowsCarryTheirProgram(t *testing.T) {
	page := "/v1/proxy/0123456789abcdef0123456789abcdef/"
	var d Desktop
	id, err := d.Apply(DeskOp{Op: "open", Kind: DeskWeb, Title: "Orders", Args: map[string]any{"page": page, "elpian": "elpian/app.js", "other": "dropped"}}, "agent", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	w := d.window(id)
	if w.Page() != page || w.Elpian() != "elpian/app.js" || w.Args["other"] != nil {
		t.Fatalf("window args: %+v", w.Args)
	}
	if !strings.Contains(d.Summary(), "Elpian app "+page) {
		t.Fatalf("summary: %s", d.Summary())
	}
	for _, bad := range []string{"/etc/passwd.js", "../x.js", "https://evil/x.js", "app.html", "a b.js", "x.js?y"} {
		var d2 Desktop
		if _, err := d2.Apply(DeskOp{Op: "open", Kind: DeskWeb, Args: map[string]any{"page": page, "elpian": bad}}, "agent", time.Now()); err == nil {
			t.Fatalf("elpian %q accepted", bad)
		}
	}
	var plain Desktop
	id, _ = plain.Apply(DeskOp{Op: "open", Kind: DeskWeb, Args: map[string]any{"page": page}}, "agent", time.Now())
	if plain.window(id).Elpian() != "" {
		t.Fatal("a web page became an Elpian app")
	}
}
