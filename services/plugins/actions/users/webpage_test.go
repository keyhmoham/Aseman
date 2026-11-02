package users

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestOnlyPublicAddressesAreFetched(t *testing.T) {
	for ip, blocked := range map[string]bool{
		"127.0.0.1": true, "10.1.2.3": true, "192.168.0.9": true, "172.16.5.5": true, "169.254.169.254": true, "100.64.0.1": true,
		"0.0.0.0": true, "::1": true, "fd00::1": true, "fe80::1": true, "93.184.216.34": false, "8.8.8.8": false, "2606:4700::1111": false,
	} {
		if blockedIP(net.ParseIP(ip)) != blocked {
			t.Errorf("%s: blocked should be %v", ip, blocked)
		}
	}
}

func TestOnlyOrdinaryWebAddressesAreRead(t *testing.T) {
	for raw, ok := range map[string]bool{
		"example.com": true, "https://example.com/about": true, "http://example.com:8080/x": false, "ftp://example.com": false,
		"file:///etc/passwd": false, "": false, "https://example.com:22": false, "http://": false,
	} {
		_, err := parseWebURL(raw)
		if (err == nil) != ok {
			t.Errorf("%q: ok should be %v (%v)", raw, ok, err)
		}
	}
}

// A page on this very machine is refused, whatever it says: the fetch is made by the node for someone else.
func TestAPageOnTheNodesOwnNetworkIsNotFetched(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("<html>secret</html>"))
	}))
	defer srv.Close()
	// The test server is on a high port on 127.0.0.1: refused twice over (the port, the address).
	if _, err := readWebpage(context.Background(), srv.URL); err == nil || strings.Contains(err.Error(), "secret") {
		t.Fatalf("a loopback page was read: %v", err)
	}
	// The address check alone, on the ordinary port.
	u, _ := url.Parse("http://127.0.0.1/")
	if err := checkWebURL(u); err != nil {
		t.Fatal(err) // the URL is fine in form; it is the dial that refuses it
	}
	if _, err := readWebpage(context.Background(), "http://127.0.0.1/"); err == nil {
		t.Fatal("loopback was fetched")
	}
}

func TestAPageIsReducedToItsReadableText(t *testing.T) {
	base, _ := url.Parse("https://bowora.com/")
	text := pageText(base, []byte(`<html><head><title>Bowora</title><meta name="description" content="Cafés, simply."><style>.x{}</style><script>var secret=1</script></head>
	<body><h1>About us</h1><p>Founded by <b>Sam</b> and <b>Ana</b>.</p><a href="/team">Meet the team</a><a href="https://other.com/x">Elsewhere</a><a href="/">Home</a></body></html>`))
	for _, want := range []string{"Title: Bowora", "Description: Cafés, simply.", "About us", "Founded by Sam and Ana", "Meet the team → /team"} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in:\n%s", want, text)
		}
	}
	for _, not := range []string{"secret", "→ /x", ".x{}"} {
		if strings.Contains(text, not) {
			t.Errorf("should not contain %q", not)
		}
	}
}

func TestANoteWithASiteIsAnswerableWithTheWebTool(t *testing.T) {
	if !mentionsSite("check bowora.com and tell me how many founders there are") || !mentionsSite("what is on https://x.org/a?b=1") || mentionsSite("hello there, how are you") {
		t.Fatal("sites are not recognised in notes")
	}
	if !voiceWantsAction("check bowora.com") || !voiceWantsAction("look at that website for me") {
		t.Fatal("a spoken request to look at a site did not get the tools")
	}
}
