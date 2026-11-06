package spaces

import (
	"strings"
	"testing"

	"github.com/aseman/aseman/pkg/errs"
)

// The node's public address comes from its settings, else from where the
// person building opens Aseman, and never is one a phone cannot reach.
func TestTheNodesPublicAddressIsOneAPhoneReaches(t *testing.T) {
	s, ctx := appAccessHarness(t)
	person := directPerson(t, s, ctx, "00000000000000010000000000000001", "founder")
	other := directPerson(t, s, ctx, "00000000000000010000000000000002", "other")

	// What compose gives a node with no public address: nothing reachable.
	t.Setenv("ASEMAN_PUBLIC_URL", "http://localhost:8080")
	t.Setenv("ASEMAN_NODE_URL", "")
	s.NodeURL = "http://aseman:8080"
	_, err := s.publicNodeURL(ctx, person, "")
	if errs.CodeOf(err) != errs.CodeUnavailable || !strings.Contains(err.Error(), "http://localhost:8080") || !strings.Contains(err.Error(), "ASEMAN_PUBLIC_URL") {
		t.Fatalf("no public address: %v", err)
	}

	// The address the person opens Aseman at, behind the web app's proxy.
	if err := s.NotePublicOrigin(ctx, person, "https://App.Example.com/"); err != nil {
		t.Fatal(err)
	}
	_ = s.NotePublicOrigin(ctx, person, "http://192.168.1.4:3000") // a LAN address is not noted
	if got, err := s.publicNodeURL(ctx, person, ""); err != nil || got != "https://app.example.com" {
		t.Fatalf("seen: %q %v", got, err)
	}
	// It is that person's own, and survives a restart.
	if _, err := s.publicNodeURL(ctx, other, ""); err == nil {
		t.Fatal("one person's address decided another's app")
	}
	s.publicOrigins = nil
	if got, _ := s.publicNodeURL(ctx, person, ""); got != "https://app.example.com" {
		t.Fatalf("after a restart: %q", got)
	}

	// The node's own URL (ASEMAN_NODE_URL / node.url) when it is public.
	s.NodeURL = "https://api.example.com"
	if got, _ := s.publicNodeURL(ctx, other, ""); got != "https://api.example.com" {
		t.Fatalf("node url: %q", got)
	}
	// ASEMAN_PUBLIC_URL first, and an address asked for over everything.
	t.Setenv("ASEMAN_PUBLIC_URL", "https://aseman.example.org/")
	if got, _ := s.publicNodeURL(ctx, person, ""); got != "https://aseman.example.org" {
		t.Fatalf("public url: %q", got)
	}
	if got, _ := s.publicNodeURL(ctx, person, "http://10.0.0.5:8080/"); got != "http://10.0.0.5:8080" {
		t.Fatalf("asked: %q", got)
	}
	if _, err := s.publicNodeURL(ctx, person, "ftp://x"); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("a bad address asked for: %v", err)
	}
}

func TestReachableFromPhones(t *testing.T) {
	for origin, want := range map[string]bool{
		"https://api.example.com": true, "http://pixelar.games:3000": true, "http://8.8.8.8": true,
		"http://localhost:8080": false, "http://127.0.0.1": false, "http://aseman:8080": false,
		"http://10.1.2.3": false, "http://192.168.0.2:3000": false, "http://[::1]:8080": false, "http://box.local": false,
	} {
		if got := reachableFromPhones(origin); got != want {
			t.Errorf("%s: %v", origin, got)
		}
	}
}
