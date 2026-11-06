package apihttp

import (
	"testing"

	network "github.com/aseman/aseman/plugins/adapters/network/ports"
)

func TestRequestOrigin(t *testing.T) {
	for _, c := range []struct {
		header map[string]string
		host   string
		want   string
	}{
		// The web app's nginx (and Caddy) forward the address people opened.
		{map[string]string{"X-Forwarded-Host": "pixelar.games:3000", "X-Forwarded-Proto": "http"}, "pixelar.games", "http://pixelar.games:3000"},
		{map[string]string{"X-Forwarded-Host": "api.example.com, inner", "X-Forwarded-Proto": "https"}, "api.example.com", "https://api.example.com"},
		// A browser straight at the node.
		{map[string]string{"Origin": "https://api.example.com"}, "api.example.com", "https://api.example.com"},
		// Another site's page is not the node's address.
		{map[string]string{"Origin": "https://evil.example"}, "api.example.com", ""},
		{map[string]string{}, "api.example.com", ""},
	} {
		if got := requestOrigin(&network.Request{Header: c.header, Host: c.host}); got != c.want {
			t.Errorf("%v: %q, want %q", c.header, got, c.want)
		}
	}
}
