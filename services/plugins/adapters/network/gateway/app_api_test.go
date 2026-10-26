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
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	network "github.com/aseman/aseman/plugins/adapters/network/ports"
)

// appSpaces adds app server access to the preview fake: user tokens are
// "user:<proxy>:<person>", the app key is "aak_key".
type appSpaces struct {
	previewSpaces
	owner identity.ID
}

func (s *appSpaces) AppUserToken(p *proxy.Proxy, viewer identity.ID) (string, error) {
	return "user:" + p.ID.String() + ":" + viewer.String(), nil
}
func (s *appSpaces) AppAPIURL() string { return "http://aseman:8080/appapi/v1" }
func (s *appSpaces) AppCaller(_ context.Context, token string) (*proxy.Access, error) {
	if token == "aak_key" {
		return &proxy.Access{Proxy: s.p, Payer: &account.Account{Entity: entity.Entity{ID: s.owner}, Kind: account.KindUser}, Via: "app Orders (background)"}, nil
	}
	parts := strings.Split(token, ":")
	if len(parts) != 3 || parts[0] != "user" || parts[1] != s.p.ID.String() {
		return nil, errs.Unauthenticated("invalid app user token")
	}
	person, _ := identity.Parse(parts[2])
	return &proxy.Access{Proxy: s.p, Payer: &account.Account{Entity: entity.Entity{ID: person}, Kind: account.KindUser}, Via: "app Orders"}, nil
}

func appRequest(op, method, token string, body any) *network.Request {
	params, _ := json.Marshal(map[string]string{"*": op})
	req := &network.Request{Method: network.Method(method), Header: map[string]string{"x-route-params": string(params)}}
	if token != "" {
		req.Header["Authorization"] = "Bearer " + token
	}
	if body != nil {
		req.Body, _ = json.Marshal(body)
	}
	return req
}

// The gateway tells an app who is using it and hands its server their token;
// the server's calls with it run as, and are billed to, that person, and its
// background calls with the app's key to the person who asked for the app.
func TestAppServersUseTheSpacesAgentsAsThePersonWhoPays(t *testing.T) {
	var seen http.Header
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r.Header.Clone()
		_, _ = w.Write([]byte("ok"))
	}))
	defer upstream.Close()

	id := identity.ID{Node: 1, Entity: 2}
	space := identity.ID{Node: 1, Entity: 3}
	viewer := identity.ID{Node: 1, Entity: 7}
	owner := identity.ID{Node: 1, Entity: 9}
	p := &proxy.Proxy{Entity: entity.Entity{ID: id}, SpaceID: space, Title: "Orders", TargetURL: upstream.URL, Token: "tunnel"}
	spaces := &appSpaces{previewSpaces: previewSpaces{p: p, member: true}, owner: owner}
	a := &API{Auth: &viewerAuth{id: viewer}, Spaces: spaces}
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
			return &api.ActionResponse{Status: 200, Body: []byte(`{"bots":[{"id":"a1","name":"Research","kind":"agent"}]}`)}, nil
		case "spaces.ask":
			return &api.ActionResponse{Status: 200, Body: []byte(`{"bot_id":"a1","reply":"done"}`)}, nil
		}
		return &api.ActionResponse{Status: 404, Body: []byte(`{"error":"nope"}`)}, nil
	}

	// A browser request: the app is told who is using it, with their token.
	browser := pageRequest(id, "orders", "GET", nil)
	browser.Header[HeaderAppUserToken] = "forged" // never taken from the browser
	if resp, err := a.proxyServe(context.Background(), browser); err != nil || resp.Status != 200 {
		t.Fatalf("proxy: %+v %v", resp, err)
	}
	token := seen.Get(HeaderAppUserToken)
	if token != "user:"+id.String()+":"+viewer.String() || seen.Get(HeaderAppUser) != viewer.String() ||
		seen.Get(HeaderAppSpace) != space.String() || seen.Get(HeaderAppAPI) != "http://aseman:8080/appapi/v1" {
		t.Fatalf("app headers: %v", seen)
	}

	// The server asks an agent with it: as the person using the app.
	resp, err := a.appAPI(context.Background(), appRequest("ask", "POST", token, map[string]any{"agent": "research", "prompt": "summarise"}))
	if err != nil || resp.Status != 200 || !strings.Contains(string(resp.Body), "done") {
		t.Fatalf("ask: %+v %v", resp, err)
	}
	ask := calls[len(calls)-1]
	if ask.action != "spaces.ask" || ask.caller != viewer || ask.body["via"] != "app Orders" || ask.body["temp_thread"] != true {
		t.Fatalf("ask dispatched as %+v", ask)
	}

	// Background work with the app's key: as the person who asked for it.
	if _, err := a.appAPI(context.Background(), appRequest("ask", "POST", "aak_key", map[string]any{"agent": "research", "prompt": "nightly"})); err != nil {
		t.Fatal(err)
	}
	ask = calls[len(calls)-1]
	if ask.caller != owner || ask.body["via"] != "app Orders (background)" {
		t.Fatalf("background ask dispatched as %+v", ask)
	}

	for _, bad := range []string{"", "forged", "user:" + identity.ID{Node: 1, Entity: 99}.String() + ":" + viewer.String()} {
		if _, err := a.appAPI(context.Background(), appRequest("ask", "POST", bad, map[string]any{"agent": "research", "prompt": "x"})); err == nil {
			t.Fatalf("token %q accepted", bad)
		}
	}
	spaces.member = false
	if _, err := a.appAPI(context.Background(), appRequest("agents", "GET", token, nil)); err == nil {
		t.Fatal("a call for someone no longer in the space was accepted")
	}
}

type viewerAuth struct{ id identity.ID }

func (a *viewerAuth) Authenticate(_ context.Context, token string) (*account.Account, error) {
	if token != "test-session" {
		return nil, errs.Unauthenticated("invalid session")
	}
	return &account.Account{Entity: entity.Entity{ID: a.id}, Kind: account.KindUser, Handle: "viewer"}, nil
}
