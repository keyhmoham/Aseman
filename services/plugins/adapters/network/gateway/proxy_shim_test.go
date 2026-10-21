package apihttp

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	network "github.com/aseman/aseman/plugins/adapters/network/ports"
)

// A page built for the site root keeps its links and forms inside the proxy:
// clicking "/about" must not land on the Aseman app sharing the origin.
func TestPreviewKeepsRootLinksInsideTheProxy(t *testing.T) {
	id := identity.ID{Node: 1, Entity: 4}
	prefix := "/v1/proxy/" + id.String() + "/"
	page := `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"></head><body>` +
		`<a href="/about">About</a><a href='/'>Home</a><a href="//cdn.example.com/x.js">cdn</a>` +
		`<a href="https://example.com/">out</a><a href="docs">rel</a><a href="` + prefix + `blog">in</a>` +
		`<form action=/login method="post"></form><img src="/logo.png"></body></html>`
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write([]byte(page))
	}))
	defer upstream.Close()
	a := &API{Auth: &previewAuth{valid: true}, Spaces: &previewSpaces{p: &proxy.Proxy{Entity: entity.Entity{ID: id}, TargetURL: upstream.URL}, member: true}}
	params, _ := json.Marshal(map[string]string{"id": id.String(), "*": ""})
	resp, err := a.proxyServe(context.Background(), &network.Request{Header: map[string]string{"x-route-params": string(params), "Authorization": "Bearer test-session"}})
	if err != nil {
		t.Fatal(err)
	}
	body := string(resp.Body)
	for _, want := range []string{
		`href="` + prefix + `about"`, `href='` + prefix + `'`, `href="//cdn.example.com/x.js"`,
		`href="https://example.com/"`, `href="docs"`, `href="` + prefix + `blog"`,
		`action=` + prefix + `login `, `src="` + prefix + `logo.png"`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("body lacks %s:\n%s", want, body)
		}
	}
	shim := strings.Index(body, "<script data-aseman-proxy>")
	if shim < 0 || shim < strings.Index(body, "<head>") || shim > strings.Index(body, "<meta") {
		t.Fatalf("navigation script not first in head:\n%s", body)
	}
	if !strings.Contains(body, `var P="`+strings.TrimRight(prefix, "/")+`"`) {
		t.Fatalf("navigation script lacks the prefix")
	}
}

func TestProxyShimOnlyTouchesHTMLOnce(t *testing.T) {
	prefix := "/v1/proxy/abc/"
	if got := string(injectProxyShim([]byte(`{"href":"/x"}`), "application/json", prefix)); got != `{"href":"/x"}` {
		t.Fatalf("json changed: %s", got)
	}
	once := injectProxyShim([]byte("<p>hi</p>"), "text/html", prefix)
	if !strings.HasPrefix(string(once), "<script data-aseman-proxy>") {
		t.Fatalf("bare fragment: %s", once)
	}
	if twice := injectProxyShim(once, "text/html", prefix); string(twice) != string(once) {
		t.Fatal("script injected twice")
	}
}
