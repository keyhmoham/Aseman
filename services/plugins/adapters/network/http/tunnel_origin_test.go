package http

import (
	"net/http/httptest"
	"testing"
)

func TestDesktopSocketOrigins(t *testing.T) {
	t.Setenv("TRADERA_ALLOWED_ORIGINS", "app.example.com, https://studio.example.com")
	t.Setenv("TRADERA_NODE_URL", "https://api.example.com")
	cases := []struct {
		name, origin, host, forwarded string
		want                          bool
	}{
		{"not a browser", "", "api.example.com", "", true},
		{"same host", "https://api.example.com", "api.example.com", "", true},
		{"app and node on different localhost ports (dev)", "http://localhost:8081", "localhost:8080", "", true},
		{"loopback address vs localhost", "http://127.0.0.1:3000", "localhost:8080", "", true},
		{"a proxy forwarded the page's host", "https://app.example.com", "tradera:8080", "app.example.com", true},
		{"listed origin (bare host)", "https://app.example.com", "tradera:8080", "", true},
		{"listed origin (url)", "https://studio.example.com", "tradera:8080", "", true},
		{"the node's own public URL", "https://api.example.com", "tradera:8080", "", true},
		{"a foreign page", "https://evil.example.net", "api.example.com", "", false},
		{"a foreign page against a local node", "https://evil.example.net", "localhost:8080", "", false},
		{"localhost page against a public node", "http://localhost:8081", "api.example.com", "", false},
		{"garbage", "not a url", "api.example.com", "", false},
	}
	for _, c := range cases {
		r := httptest.NewRequest("GET", "/v1/proxy/x/websockify", nil)
		r.Host = c.host
		if c.origin != "" {
			r.Header.Set("Origin", c.origin)
		}
		if c.forwarded != "" {
			r.Header.Set("X-Forwarded-Host", c.forwarded)
		}
		if got := originAllowed(r); got != c.want {
			t.Errorf("%s: origin %q host %q -> %v, want %v", c.name, c.origin, c.host, got, c.want)
		}
	}
}
