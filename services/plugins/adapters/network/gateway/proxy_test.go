package apihttp

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	network "github.com/aseman/aseman/plugins/adapters/network/ports"
)

type previewAuth struct {
	valid bool
	calls int
}

func (a *previewAuth) Authenticate(_ context.Context, token string) (*account.Account, error) {
	a.calls++
	if !a.valid || token != "test-session" {
		return nil, errs.Unauthenticated("invalid session")
	}
	return &account.Account{Kind: account.KindUser}, nil
}

type previewSpaces struct {
	FileSpaces
	p      *proxy.Proxy
	member bool
	checks int
}

func (s *previewSpaces) ProxyGet(context.Context, identity.ID) (*proxy.Proxy, error) { return s.p, nil }
func (s *previewSpaces) SpaceMembership(context.Context, identity.ID, identity.ID) (*membership.Membership, error) {
	s.checks++
	if !s.member {
		return nil, errs.Permission("removed")
	}
	return &membership.Membership{}, nil
}
func TestPreviewAuthenticatesEveryAssetAndPreservesFrameworkProtocol(t *testing.T) {
	id := identity.ID{Node: 1, Entity: 2}
	prefix := "/v1/proxy/" + id.String() + "/"
	requests := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if r.URL.Path != prefix+"blog" || r.URL.Query().Get("token") != "" || r.URL.Query().Get("page") != "2" {
			t.Errorf("upstream URL %s", r.URL)
		}
		if r.Header.Get("Authorization") != "Bearer tunnel-secret" || r.Header.Get("RSC") != "1" || r.Header.Get("Next-Router-State-Tree") != "router-state" {
			t.Errorf("protocol headers %v", r.Header)
		}
		w.Header().Set("Content-Type", "text/x-component")
		w.Header().Set("Vary", "RSC, Next-Router-State-Tree")
		w.Write([]byte(`{"asset":"` + prefix + `_next/static/a.js"}`))
	}))
	defer upstream.Close()
	auth := &previewAuth{valid: true}
	spaces := &previewSpaces{p: &proxy.Proxy{Entity: entity.Entity{ID: id}, TargetURL: upstream.URL + prefix, Token: "tunnel-secret"}, member: true}
	a := &API{Auth: auth, Spaces: spaces}
	params, _ := json.Marshal(map[string]string{"id": id.String(), "*": "blog"})
	req := &network.Request{Header: map[string]string{"x-route-params": string(params), "Authorization": "Bearer test-session", "RSC": "1", "Next-Router-State-Tree": "router-state"}, Query: map[string][]string{"token": {"test-session"}, "page": {"2"}}}
	result, err := a.proxyServe(context.Background(), req)
	if err != nil || result.Status != 200 || strings.Contains(string(result.Body), prefix+"v1/proxy") || result.Header["Vary"] == "" {
		t.Fatalf("response=%+v err=%v", result, err)
	}
	cookies := (&http.Response{Header: http.Header{"Set-Cookie": {result.Header["Set-Cookie"]}}}).Cookies()
	if len(cookies) != 1 || !cookies[0].HttpOnly || cookies[0].Path != strings.TrimRight(prefix, "/") {
		t.Fatalf("cookies %+v", cookies)
	}
	delete(req.Header, "Authorization")
	delete(req.Query, "token")
	req.Header["Cookie"] = cookies[0].Name + "=" + cookies[0].Value
	if _, err = a.proxyServe(context.Background(), req); err != nil {
		t.Fatal(err)
	}
	auth.valid = false
	if _, err = a.proxyServe(context.Background(), req); err == nil {
		t.Fatal("revoked session accepted")
	}
	auth.valid = true
	spaces.member = false
	if _, err = a.proxyServe(context.Background(), req); err == nil {
		t.Fatal("removed membership accepted")
	}
	spaces.member = true
	req.Header["Cookie"] = cookies[0].Name + "=ok"
	if _, err = a.proxyServe(context.Background(), req); err == nil {
		t.Fatal("forged legacy cookie accepted")
	}
	req.Header["Cookie"] = cookies[0].Name + "=" + base64.RawURLEncoding.EncodeToString([]byte("invalid"))
	if _, err = a.proxyServe(context.Background(), req); err == nil {
		t.Fatal("forged credential accepted")
	}
	if requests != 2 || auth.calls < 5 || spaces.checks != 3 {
		t.Fatalf("requests=%d auth=%d membership=%d", requests, auth.calls, spaces.checks)
	}
}
func TestPreviewDoesNotFollowUpstreamRedirect(t *testing.T) {
	id := identity.ID{Node: 1, Entity: 2}
	hits := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Header().Set("Location", "/login")
		w.WriteHeader(307)
	}))
	defer upstream.Close()
	p := &proxy.Proxy{Entity: entity.Entity{ID: id}, TargetURL: upstream.URL}
	a := &API{Auth: &previewAuth{valid: true}, Spaces: &previewSpaces{p: p, member: true}}
	params, _ := json.Marshal(map[string]string{"id": id.String()})
	resp, err := a.proxyServe(context.Background(), &network.Request{Header: map[string]string{"x-route-params": string(params), "Authorization": "Bearer test-session"}})
	if err != nil || resp.Status != 307 || resp.Header["Location"] != p.GatewayPath()+"login" || hits != 1 {
		t.Fatalf("%+v %v hits=%d", resp, err, hits)
	}
}

func TestPathPreservingGatewayRetainsApplicationRootSlashSemantics(t *testing.T) {
	id := identity.ID{Node: 1, Entity: 2}
	prefix := "/v1/proxy/" + id.String() + "/"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == strings.TrimRight(prefix, "/") {
			w.Header().Set("Location", prefix)
			w.WriteHeader(308)
			return
		}
		if r.URL.Path != prefix {
			t.Errorf("path %s", r.URL.Path)
		}
		w.Write([]byte("served page"))
	}))
	defer upstream.Close()
	p := &proxy.Proxy{Entity: entity.Entity{ID: id}, TargetURL: upstream.URL + prefix}
	a := &API{Auth: &previewAuth{valid: true}, Spaces: &previewSpaces{p: p, member: true}}
	params, _ := json.Marshal(map[string]string{"id": id.String(), "*": ""})
	for _, tc := range []struct {
		path   string
		status int
	}{{prefix, 200}, {strings.TrimRight(prefix, "/"), 308}} {
		resp, err := a.proxyServe(context.Background(), &network.Request{Path: tc.path, Header: map[string]string{"x-route-params": string(params), "Authorization": "Bearer test-session"}})
		if err != nil || resp.Status != tc.status {
			t.Fatalf("path=%s response=%+v err=%v", tc.path, resp, err)
		}
		if tc.status == 200 && string(resp.Body) != "served page" {
			t.Fatal("root failed to serve actual HTML")
		}
		if tc.status == 308 && resp.Header["Location"] != prefix {
			t.Fatal("root redirect changed prefix")
		}
	}
}

// A preview is an app: its forms post through the gateway, the sign-in cookie
// works inside the app's frame over HTTPS, and no other site can post with it.
func TestPreviewForwardsPostsAndGuardsTheCookie(t *testing.T) {
	id := identity.ID{Node: 1, Entity: 3}
	prefix := "/v1/proxy/" + id.String() + "/"
	var got struct{ method, body, ctype string }
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		got.method, got.body, got.ctype = r.Method, string(data), r.Header.Get("Content-Type")
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"success":true}`))
	}))
	defer upstream.Close()
	a := &API{Auth: &previewAuth{valid: true}, Spaces: &previewSpaces{p: &proxy.Proxy{Entity: entity.Entity{ID: id}, TargetURL: upstream.URL + prefix, Token: "tunnel-secret"}, member: true}}
	params, _ := json.Marshal(map[string]string{"id": id.String(), "*": "api/suggestions"})

	// The first load over HTTPS sets a cookie a framed page can use.
	first, err := a.proxyServe(context.Background(), &network.Request{Method: network.MethodGet, Header: map[string]string{"x-route-params": string(params), "X-Forwarded-Proto": "https"}, Query: map[string][]string{"token": {"test-session"}}})
	if err != nil {
		t.Fatal(err)
	}
	set := first.Header["Set-Cookie"]
	for _, want := range []string{"SameSite=None", "Secure", "Partitioned", "HttpOnly"} {
		if !strings.Contains(set, want) {
			t.Fatalf("cookie %q lacks %s", set, want)
		}
	}
	cookies := (&http.Response{Header: http.Header{"Set-Cookie": {set}}}).Cookies()
	cookie := cookies[0].Name + "=" + cookies[0].Value

	post := func(site string) (*network.Response, error) {
		h := map[string]string{"x-route-params": string(params), "Cookie": cookie, "Content-Type": "application/json"}
		if site != "" {
			h["Sec-Fetch-Site"] = site
		}
		return a.proxyServe(context.Background(), &network.Request{Method: network.MethodPost, Header: h, Body: []byte(`{"name":"Alex"}`)})
	}
	if _, err := post("same-origin"); err != nil {
		t.Fatal(err)
	}
	if got.method != http.MethodPost || got.body != `{"name":"Alex"}` || got.ctype != "application/json" {
		t.Fatalf("the form did not reach the app: %+v", got)
	}
	got.method = ""
	if _, err := post("cross-site"); errs.CodeOf(err) != errs.CodePermission || got.method != "" {
		t.Fatalf("another site posted with the person's sign-in: %v (reached app: %q)", err, got.method)
	}
}
