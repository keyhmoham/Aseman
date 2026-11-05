package apihttp

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	network "github.com/aseman/aseman/plugins/adapters/network/ports"
)

// platformSpaces is a space whose app is the frontend of platform "acme":
// platform user tokens are "pf:<proxy>:<person>", run as the publisher.
type platformSpaces struct {
	appSpaces
	pf        *models.PlatformFrontend
	allowed   map[identity.ID]bool // who may use the platform
	publisher identity.ID
	woken     int
}

func (s *platformSpaces) PlatformFrontendFor(_ context.Context, ref string, viewer identity.ID) (*models.PlatformFrontend, error) {
	if ref != s.pf.Slug {
		return nil, errs.NotFound("platform")
	}
	if !viewer.IsZero() && !s.allowed[viewer] {
		return nil, errs.Permission("this account is not on Acme")
	}
	return s.pf, nil
}

// Only the publisher is a member of the app's space.
func (s *platformSpaces) SpaceMembership(_ context.Context, _ identity.ID, who identity.ID) (*membership.Membership, error) {
	if who != s.publisher {
		return nil, errs.Permission("not a member")
	}
	return &membership.Membership{}, nil
}
func (s *platformSpaces) PlatformUserToken(p *proxy.Proxy, viewer identity.ID, platformID string) (string, error) {
	return "pf:" + p.ID.String() + ":" + viewer.String(), nil
}
func (s *platformSpaces) AppCaller(ctx context.Context, token string) (*proxy.Access, error) {
	if rest, ok := strings.CutPrefix(token, "pf:"); ok {
		parts := strings.Split(rest, ":")
		person, _ := identity.Parse(parts[1])
		return &proxy.Access{Proxy: s.p, Via: "platform Acme · app Store for @shopper", Platform: s.pf,
			Payer: &account.Account{Entity: entity.Entity{ID: s.publisher}, Kind: account.KindUser},
			User:  &account.Account{Entity: entity.Entity{ID: person}, Kind: account.KindUser, Handle: "shopper"}}, nil
	}
	return s.appSpaces.AppCaller(ctx, token)
}
func (s *platformSpaces) ProxyOpen(context.Context, identity.ID, identity.ID) (map[string]any, error) {
	s.woken++
	return map[string]any{"ready": true}, nil
}

func platformRequest(slug, rest, method, token string, body any) *network.Request {
	params, _ := json.Marshal(map[string]string{"slug": slug, "*": rest})
	req := &network.Request{Method: network.Method(method), Header: map[string]string{"x-route-params": string(params)}}
	if token != "" {
		req.Header["Authorization"] = "Bearer " + token
	}
	if body != nil {
		req.Body, _ = json.Marshal(body)
	}
	return req
}

// A sub-platform's people open the frontend an agent built in a space they
// are not members of; the app's page and server reach the space's agents and
// apps as the person who published it, for them, and only what it is wired to.
func TestPlatformFrontendServesThePlatformsPeopleWithinItsWiring(t *testing.T) {
	var seen http.Header
	var seenPath string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen, seenPath = r.Header.Clone(), r.URL.Path
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte(`<html><head></head><body><img src="/logo.png"></body></html>`))
	}))
	defer upstream.Close()

	id := identity.ID{Node: 1, Entity: 2}
	space := identity.ID{Node: 1, Entity: 3}
	shopper := identity.ID{Node: 1, Entity: 7}
	publisher := identity.ID{Node: 1, Entity: 9}
	p := &proxy.Proxy{Entity: entity.Entity{ID: id}, SpaceID: space, Title: "Store", TargetURL: upstream.URL, Token: "tunnel",
		Path: "/v1/proxy/" + id.String() + "/"}
	pf := &models.PlatformFrontend{PlatformID: "pf1", Slug: "acme", Name: "Acme", ProxyID: id.String(), SpaceID: space.String(),
		Publisher: publisher.String(), Wiring: models.Wiring{
			Agents: []models.WiredAgent{{ID: "a1", Name: "Research"}},
			Apps:   []models.WiredApp{{ID: "t1", Name: "Weather", Microtools: []string{"forecast"}}},
		}}
	spaces := &platformSpaces{
		appSpaces: appSpaces{previewSpaces: previewSpaces{p: p, member: false}, owner: publisher},
		pf:        pf, allowed: map[identity.ID]bool{shopper: true}, publisher: publisher,
	}
	a := &API{Auth: &viewerAuth{id: shopper}, Spaces: spaces}
	type dispatched struct {
		action string
		caller identity.ID
		body   map[string]any
	}
	var calls []dispatched
	a.pageActions = func(_ context.Context, ns, action string, req *api.ActionRequest) (*api.ActionResponse, error) {
		var body map[string]any
		_ = json.Unmarshal(req.Body, &body)
		calls = append(calls, dispatched{ns + "." + action, req.Caller.ID, body})
		switch ns + "." + action {
		case "spaces.bots_list":
			return &api.ActionResponse{Status: 200, Body: []byte(`{"bots":[{"id":"a1","name":"Research","kind":"agent"},{"id":"a2","name":"Finance","kind":"agent"}]}`)}, nil
		case "spaces.tools_list":
			return &api.ActionResponse{Status: 200, Body: []byte(`{"tools":[{"name":"Weather","bot_id":"t1"},{"name":"Payroll","bot_id":"t2"}]}`)}, nil
		case "spaces.ask":
			return &api.ActionResponse{Status: 200, Body: []byte(`{"bot_id":"a1","reply":"done"}`)}, nil
		case "tools.invoke":
			return &api.ActionResponse{Status: 200, Body: []byte(`{"result":"sunny"}`)}, nil
		}
		return &api.ActionResponse{Status: 404, Body: []byte(`{"error":"nope"}`)}, nil
	}
	ctx := context.Background()

	// A visitor who has not signed in sees the pages, with no person headers,
	// under the platform's own path.
	resp, err := a.platformServe(ctx, platformRequest("acme", "", "GET", "", nil))
	if err != nil || resp.Status != 200 {
		t.Fatalf("visitor: %+v %v", resp, err)
	}
	if seen.Get(HeaderAppUserToken) != "" || seen.Get(HeaderAppPlatform) != "acme" || seen.Get(HeaderAppPlatformID) != "pf1" {
		t.Fatalf("visitor headers: %v", seen)
	}
	if seen.Get("X-Forwarded-Prefix") != "/v1/platforms/acme/app" || !strings.Contains(string(resp.Body), `/v1/platforms/acme/app/logo.png`) {
		t.Fatalf("not served under the platform's path: %s %s", seen.Get("X-Forwarded-Prefix"), resp.Body)
	}
	if _, err := a.platformServe(ctx, platformRequest("acme", "_aseman/api/agents", "GET", "", nil)); errs.CodeOf(err) != errs.CodeUnauthenticated {
		t.Fatalf("a visitor reached the space's agents: %v", err)
	}

	// A person of the platform (not of the space) gets a platform user token.
	if _, err := a.platformServe(ctx, platformRequest("acme", "shop", "GET", "test-session", nil)); err != nil {
		t.Fatal(err)
	}
	token := seen.Get(HeaderAppUserToken)
	if token != "pf:"+id.String()+":"+shopper.String() || seen.Get(HeaderAppUser) != shopper.String() || seenPath != "/shop" {
		t.Fatalf("person headers: %v %s", seen, seenPath)
	}

	// The page lists and uses only what the app is wired to, as the publisher.
	resp, err = a.platformServe(ctx, platformRequest("acme", "_aseman/api/agents", "GET", "test-session", nil))
	if err != nil || strings.Contains(string(resp.Body), "Finance") || !strings.Contains(string(resp.Body), "Research") {
		t.Fatalf("agents: %s %v", resp.Body, err)
	}
	resp, err = a.platformServe(ctx, platformRequest("acme", "_aseman/api/ask", "POST", "test-session", map[string]any{"agent": "research", "prompt": "hi"}))
	if err != nil || !strings.Contains(string(resp.Body), "done") {
		t.Fatalf("ask: %+v %v", resp, err)
	}
	ask := calls[len(calls)-1]
	if ask.action != "spaces.ask" || ask.caller != publisher || ask.body["via"] != "platform Acme · app Store for @shopper" {
		t.Fatalf("ask dispatched as %+v", ask)
	}
	resp, _ = a.platformServe(ctx, platformRequest("acme", "_aseman/api/ask", "POST", "test-session", map[string]any{"agent": "Finance", "prompt": "pay me"}))
	if resp == nil || resp.Status != http.StatusForbidden || !strings.Contains(string(resp.Body), "wired") {
		t.Fatalf("an agent the app is not wired to was asked: %+v", resp)
	}
	resp, _ = a.platformServe(ctx, platformRequest("acme", "_aseman/api/call", "POST", "test-session", map[string]any{"tool": "Payroll", "microtool": "run", "args": map[string]any{}}))
	if resp == nil || resp.Status != http.StatusForbidden {
		t.Fatalf("an app the app is not wired to was called: %+v", resp)
	}
	resp, _ = a.platformServe(ctx, platformRequest("acme", "_aseman/api/call", "POST", "test-session", map[string]any{"tool": "Weather", "microtool": "delete_all", "args": map[string]any{}}))
	if resp == nil || resp.Status != http.StatusForbidden {
		t.Fatalf("a microtool the app is not wired to was called: %+v", resp)
	}
	resp, err = a.platformServe(ctx, platformRequest("acme", "_aseman/api/call", "POST", "test-session", map[string]any{"tool": "weather", "microtool": "forecast", "args": map[string]any{"city": "Oslo"}}))
	if err != nil || !strings.Contains(string(resp.Body), "sunny") || calls[len(calls)-1].caller != publisher {
		t.Fatalf("call: %+v %v", resp, err)
	}
	resp, err = a.platformServe(ctx, platformRequest("acme", "_aseman/api/context", "GET", "test-session", nil))
	if err != nil || !strings.Contains(string(resp.Body), `"slug":"acme"`) || !strings.Contains(string(resp.Body), shopper.String()) {
		t.Fatalf("context: %s %v", resp.Body, err)
	}

	// The app's server, with the request's token: the same, within the wiring.
	resp, err = a.appAPI(ctx, appRequest("ask", "POST", token, map[string]any{"agent": "a1", "prompt": "summarise"}))
	if err != nil || resp.Status != 200 || calls[len(calls)-1].caller != publisher {
		t.Fatalf("server ask: %+v %v", resp, err)
	}
	resp, _ = a.appAPI(ctx, appRequest("ask", "POST", token, map[string]any{"agent": "a2", "prompt": "x"}))
	if resp == nil || resp.Status != http.StatusForbidden {
		t.Fatalf("server asked an agent it is not wired to: %+v", resp)
	}

	// Someone who is not on the platform is refused.
	a.Auth = &viewerAuth{id: identity.ID{Node: 1, Entity: 42}}
	if _, err := a.platformServe(ctx, platformRequest("acme", "", "GET", "test-session", nil)); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("someone off the platform got in: %v", err)
	}
	if _, err := a.platformServe(ctx, platformRequest("nope", "", "GET", "", nil)); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("unknown platform: %v", err)
	}
}

// A frontend whose computer is asleep is woken as its publisher.
func TestPlatformFrontendWakesItsComputer(t *testing.T) {
	up := false
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("ok")) }))
	defer upstream.Close()
	id := identity.ID{Node: 1, Entity: 2}
	p := &proxy.Proxy{Entity: entity.Entity{ID: id}, SpaceID: identity.ID{Node: 1, Entity: 3}, Title: "Store", TargetURL: "http://127.0.0.1:1", Token: "t"}
	spaces := &platformSpaces{
		appSpaces: appSpaces{previewSpaces: previewSpaces{p: p}},
		pf:        &models.PlatformFrontend{PlatformID: "pf1", Slug: "acme", Name: "Acme", ProxyID: id.String(), Publisher: identity.ID{Node: 1, Entity: 9}.String()},
	}
	a := &API{Auth: &viewerAuth{}, Spaces: &wakingSpaces{platformSpaces: spaces, wake: func() { up = true; p.TargetURL = upstream.URL }}}
	resp, err := a.platformServe(context.Background(), platformRequest("acme", "", "GET", "", nil))
	if err != nil || resp.Status != 200 || !up {
		t.Fatalf("not woken: %+v %v", resp, err)
	}
}

type wakingSpaces struct {
	*platformSpaces
	wake func()
}

func (s *wakingSpaces) ProxyOpen(ctx context.Context, id, actor identity.ID) (map[string]any, error) {
	s.wake()
	return s.platformSpaces.ProxyOpen(ctx, id, actor)
}

// A web frontend signs the platform's people in through the gateway: the
// session lands in the frontend's HttpOnly cookie, never in the page.
func TestPlatformFrontendSignsPeopleInToThePlatform(t *testing.T) {
	id := identity.ID{Node: 1, Entity: 2}
	p := &proxy.Proxy{Entity: entity.Entity{ID: id}, SpaceID: identity.ID{Node: 1, Entity: 3}, Title: "Store", TargetURL: "http://127.0.0.1:1"}
	spaces := &platformSpaces{
		appSpaces: appSpaces{previewSpaces: previewSpaces{p: p}},
		pf:        &models.PlatformFrontend{PlatformID: "pf1", Slug: "acme", Name: "Acme", ProxyID: id.String()},
	}
	a := &API{Auth: &viewerAuth{id: identity.ID{Node: 1, Entity: 7}}, Spaces: spaces}
	var seen map[string]any
	a.pageActions = func(_ context.Context, ns, action string, req *api.ActionRequest) (*api.ActionResponse, error) {
		_ = json.Unmarshal(req.Body, &seen)
		seen["action"] = ns + "." + action
		return &api.ActionResponse{Status: 200, Body: []byte(`{"token":"test-session","account_id":"u7","handle":"shopper","private_key":"secret"}`)}, nil
	}
	ctx := context.Background()
	resp, err := a.platformServe(ctx, platformRequest("acme", "_aseman/auth/login", "POST", "", map[string]any{"account": "shopper", "password": "pw", "platform": "other"}))
	if err != nil || resp.Status != 200 {
		t.Fatalf("login: %+v %v", resp, err)
	}
	if seen["action"] != "auth.login" || seen["platform"] != "acme" || seen["account"] != "shopper" {
		t.Fatalf("login dispatched as %+v", seen)
	}
	if strings.Contains(string(resp.Body), "test-session") || strings.Contains(string(resp.Body), "secret") {
		t.Fatalf("the page got the session: %s", resp.Body)
	}
	cookie := resp.Header["Set-Cookie"]
	if !strings.Contains(cookie, "oc_platform_acme=") || !strings.Contains(cookie, "HttpOnly") || !strings.Contains(cookie, "Path=/v1/platforms/acme/app") {
		t.Fatalf("cookie: %s", cookie)
	}
	if _, err := a.platformServe(ctx, platformRequest("acme", "_aseman/auth/register", "POST", "", map[string]any{"handle": "new", "email": "n@x.test", "password": "pw"})); err != nil || seen["action"] != "auth.register" || seen["platform"] != "acme" {
		t.Fatalf("register: %+v %v", seen, err)
	}
	cross := platformRequest("acme", "_aseman/auth/login", "POST", "", map[string]any{"account": "x", "password": "y"})
	cross.Header["Sec-Fetch-Site"] = "cross-site"
	if _, err := a.platformServe(ctx, cross); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("another site signed someone in: %v", err)
	}
	me, err := a.platformServe(ctx, platformRequest("acme", "_aseman/auth/me", "GET", "", nil))
	if err != nil || !strings.Contains(string(me.Body), `"user":null`) {
		t.Fatalf("me (visitor): %s %v", me.Body, err)
	}
	out, err := a.platformServe(ctx, platformRequest("acme", "_aseman/auth/logout", "POST", "", nil))
	if err != nil || !strings.Contains(out.Header["Set-Cookie"], "Max-Age=0") {
		t.Fatalf("logout: %+v %v", out, err)
	}
}
