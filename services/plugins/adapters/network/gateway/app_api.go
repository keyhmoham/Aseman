package apihttp

// The app API serves the backend of an app in a space's sandbox the same page
// API its pages use (_aseman/api/<op>: context, tools, microtools, call,
// agents, ask, frontend, show, file/<id>), at /appapi/v1/<op> on the node.
//
// A server authenticates with Authorization: Bearer and either:
//   - the user token the gateway added to the request it is serving
//     (X-Aseman-User-Token): the call runs as, and is billed to, the person
//     using the app;
//   - the app's key (ASEMAN_APP_KEY) for work nobody is in front of: the call
//     runs as, and is billed to, the person who asked for the app.
//
// Either way the call goes through exactly the actions a person's own call
// does, so funds, budgets and usage records are the person's (spaces.ask).

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/internal/plugins/signing"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// Headers the gateway adds to every request it forwards to an app.
const (
	HeaderAppUserToken  = "X-Aseman-User-Token"
	HeaderAppUser       = "X-Aseman-User"
	HeaderAppUserHandle = "X-Aseman-User-Handle"
	HeaderAppSpace      = "X-Aseman-Space"
	HeaderAppRoom       = "X-Aseman-Room"
	HeaderAppAPI        = "X-Aseman-Api"
)

// appAccess is the spaces service's side of app server access.
type appAccess interface {
	AppUserToken(p *proxy.Proxy, viewer identity.ID) (string, error)
	AppCaller(ctx context.Context, token string) (*proxy.Access, error)
	AppAPIURL() string
}

type viaKey struct{}

// withVia names the app a page API call comes from, for usage records.
func withVia(ctx context.Context, via string) context.Context {
	return context.WithValue(ctx, viaKey{}, via)
}

func viaFrom(ctx context.Context) string {
	v, _ := ctx.Value(viaKey{}).(string)
	return v
}

// appHeaders are the headers of a request forwarded to an app for [viewer]:
// who is using it, where, and the token its server acts for them with.
func (a *API) appHeaders(p *proxy.Proxy, viewerID identity.ID, handle string) map[string]string {
	access, ok := a.Spaces.(appAccess)
	if !ok {
		return nil
	}
	token, err := access.AppUserToken(p, viewerID)
	if err != nil {
		return nil
	}
	h := map[string]string{
		HeaderAppUserToken: token, HeaderAppUser: viewerID.String(), HeaderAppUserHandle: handle,
		HeaderAppSpace: p.SpaceID.String(), HeaderAppAPI: access.AppAPIURL(),
	}
	if !p.RoomID.IsZero() {
		h[HeaderAppRoom] = p.RoomID.String()
	}
	return h
}

// appAPI answers an app server's /appapi/v1/<op>.
func (a *API) appAPI(ctx context.Context, req *network.Request) (*network.Response, error) {
	access, ok := a.Spaces.(appAccess)
	if !ok || a.Spaces == nil {
		return nil, errs.New(errs.CodeUnavailable, "app API unavailable")
	}
	token := strings.TrimSpace(strings.TrimPrefix(signing.Header(req.Header, "Authorization"), "Bearer "))
	if token == "" {
		return nil, errs.Unauthenticated("send the request's " + HeaderAppUserToken + " or the app's key as Authorization: Bearer")
	}
	who, err := access.AppCaller(ctx, token)
	if err != nil {
		return nil, err
	}
	// Whoever pays must still belong to the app's space, on every call.
	if _, err := a.Spaces.SpaceMembership(ctx, who.Proxy.SpaceID, who.Payer.ID); err != nil {
		return nil, errs.Permission("the person this app acts for is not a member of its space")
	}
	params := map[string]string{}
	if raw := req.Header["x-route-params"]; raw != "" {
		_ = json.Unmarshal([]byte(raw), &params)
	}
	op := strings.Trim(params["*"], "/")
	if op == "" {
		return nil, errs.NotFound("name the op: /appapi/v1/<context|tools|microtools|call|agents|ask|frontend|show|file/<id>>")
	}
	method := string(req.Method)
	if method == "" || req.Method == network.MethodCall {
		method = http.MethodGet
	}
	p := who.Proxy
	if who.Platform != nil {
		p = platformView(p, who.Platform.Slug)
	}
	return a.proxyPage(withPlatformCall(withVia(ctx, who.Via), who), req, p, who.Payer, method, "api/"+op)
}
