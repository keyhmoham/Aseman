package apihttp

// A platform's frontend (developer/platform_frontend.go) is an app the
// agents of a space built, served to the platform's people at
// /v1/platforms/<slug>/app/ — the same preview as /v1/proxy/<id>/, with
// another door:
//
//   - Who may open it: anyone may load its pages (a visitor who has not
//     signed in gets no person headers); a signed-in viewer must be someone
//     of the platform (or of main Aseman when the platform is bridged to it,
//     or of the organization). The space's membership is not asked for: the
//     platform's people are not the space's.
//   - What it reaches: the page's _aseman/api and the app's server
//     (X-Aseman-User-Token, a platform user token) use the space's agents and
//     apps as the frontend's publisher, for the signed-in person, and only
//     the agents and apps the app is wired to. Visitors who have not signed
//     in reach none of them.
//   - A computer asleep is woken (as the publisher) on the first request that
//     finds the app's service down.

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// Headers the gateway adds to every request it forwards to a platform's
// frontend (with the app headers of a signed-in person).
const (
	HeaderAppPlatform     = "X-Aseman-Platform"
	HeaderAppPlatformID   = "X-Aseman-Platform-Id"
	HeaderAppPlatformName = "X-Aseman-Platform-Name"
)

// platformFrontends is what the gateway needs to serve platform frontends.
type platformFrontends interface {
	PlatformFrontendFor(ctx context.Context, ref string, viewer identity.ID) (*models.PlatformFrontend, error)
	PlatformUserToken(p *proxy.Proxy, viewer identity.ID, platformID string) (string, error)
	AppCaller(ctx context.Context, token string) (*proxy.Access, error)
	AppAPIURL() string
	ProxyOpen(ctx context.Context, id, actor identity.ID) (map[string]any, error)
}

// platformAppPath is where a platform's frontend is served.
func platformAppPath(slug string) string { return "/v1/platforms/" + slug + "/app/" }

type platformCallKey struct{}

// withPlatformCall marks a page API call as a platform frontend's: it runs as
// the publisher for the platform's person, within the app's wiring.
func withPlatformCall(ctx context.Context, who *proxy.Access) context.Context {
	if who == nil || who.Platform == nil {
		return ctx
	}
	return context.WithValue(ctx, platformCallKey{}, who)
}

func platformCallFrom(ctx context.Context) *proxy.Access {
	who, _ := ctx.Value(platformCallKey{}).(*proxy.Access)
	return who
}

// platformAllowsAgent is false only for a platform call naming an agent the
// app is not wired to.
func platformAllowsAgent(ctx context.Context, id, name string) bool {
	who := platformCallFrom(ctx)
	return who == nil || who.Platform.Wiring.AllowsAgent(id) || who.Platform.Wiring.AllowsAgent(name)
}

// platformAllowsApp is false only for a platform call naming an app (or a
// microtool of it) the app is not wired to.
func platformAllowsApp(ctx context.Context, id, name, microtool string) bool {
	who := platformCallFrom(ctx)
	return who == nil || who.Platform.Wiring.AllowsApp(id, microtool) || who.Platform.Wiring.AllowsApp(name, microtool)
}

func notWired(what, name string) error {
	return errs.Permission(name + " is not one of the " + what + " this platform's frontend is wired to (its APPS.json when it was published); ask the space's agents to wire it and publish the frontend again")
}

// platformServe answers /v1/platforms/{slug}/app/*.
func (a *API) platformServe(ctx context.Context, req *network.Request) (*network.Response, error) {
	params := map[string]string{}
	if raw := req.Header["x-route-params"]; raw != "" {
		_ = json.Unmarshal([]byte(raw), &params)
	}
	slug := strings.ToLower(strings.TrimSpace(params["slug"]))
	if slug == "" {
		return nil, errs.NotFound("name the platform")
	}
	pfs, ok := a.Spaces.(platformFrontends)
	if !ok || a.Spaces == nil {
		return nil, errs.New(errs.CodeUnavailable, "platform frontends are unavailable")
	}
	method := string(req.Method)
	if method == "" || req.Method == network.MethodCall {
		method = http.MethodGet
	}
	cookieName := "oc_platform_" + strings.ReplaceAll(slug, "-", "_")
	token, fromCookie := requestToken(req, cookieName)
	if method != http.MethodGet && fromCookie && !sameOrigin(req) {
		return nil, errs.Permission("this request did not come from the platform's own page")
	}
	var acc *account.Account
	if token != "" {
		var err error
		if acc, err = a.Auth.Authenticate(ctx, token); err != nil {
			if !fromCookie {
				return nil, err
			}
			// A session that ended: the page is still open to visitors.
			acc, token = nil, ""
		}
		if acc != nil && acc.Kind == account.KindBot {
			return nil, errs.Unauthenticated("a platform's frontend is for people")
		}
	}
	var viewer identity.ID
	if acc != nil {
		viewer = acc.ID
	}
	pf, err := pfs.PlatformFrontendFor(ctx, slug, viewer)
	if err != nil {
		return nil, err
	}
	pid, err := identity.Parse(pf.ProxyID)
	if err != nil {
		return nil, errs.NotFound("the platform's frontend app")
	}
	p, err := a.Spaces.ProxyGet(ctx, pid)
	if err != nil {
		return nil, errs.NotFound("the platform's frontend app was deleted; publish another")
	}
	view := platformView(p, pf.Slug)

	rest := params["*"]
	if page, ok := strings.CutPrefix(strings.TrimLeft(rest, "/"), pagePrefix); ok {
		if strings.HasPrefix(page, "kit/") {
			return a.proxyPage(ctx, req, view, nil, method, page)
		}
		if op, ok := strings.CutPrefix(page, "auth/"); ok {
			return a.platformAuth(ctx, req, pf, view, cookieName, acc, method, strings.Trim(op, "/"))
		}
		if acc == nil {
			return nil, errs.Unauthenticated("sign in to " + pf.Name + " to use this")
		}
		who, err := a.platformCaller(ctx, pfs, p, acc, pf)
		if err != nil {
			return nil, err
		}
		return a.proxyPage(withPlatformCall(withVia(ctx, who.Via), who), req, view, who.Payer, method, page)
	}

	headers := map[string]string{
		HeaderAppPlatform: pf.Slug, HeaderAppPlatformID: pf.PlatformID, HeaderAppPlatformName: pf.Name,
		HeaderAppSpace: p.SpaceID.String(), HeaderAppAPI: pfs.AppAPIURL(),
	}
	if acc != nil {
		userToken, err := pfs.PlatformUserToken(p, acc.ID, pf.PlatformID)
		if err != nil {
			return nil, err
		}
		headers[HeaderAppUserToken], headers[HeaderAppUser], headers[HeaderAppUserHandle] = userToken, acc.ID.String(), acc.Handle
	}
	fw := proxyForward{rest: rest, method: method, headers: headers, socket: func() error {
		if acc == nil {
			return errs.Unauthenticated("sign in to " + pf.Name + " to use this")
		}
		return nil
	}}
	if token != "" && !fromCookie {
		fw.cookie = proxyCookie(req, cookieName, token, view.GatewayPath())
	}
	resp, err := a.forwardProxy(ctx, req, view, fw)
	if err == nil || errs.CodeOf(err) != errs.CodeUnavailable {
		return resp, err
	}
	// The app's computer is asleep (or its service stopped): wake it as the
	// person who published the frontend, and try once more.
	publisher, perr := identity.Parse(pf.Publisher)
	if perr != nil {
		return nil, err
	}
	if _, werr := pfs.ProxyOpen(ctx, p.ID, publisher); werr != nil {
		return nil, errs.New(errs.CodeUnavailable, pf.Name+" is starting up and could not be woken: "+werr.Error())
	}
	if fresh, ferr := a.Spaces.ProxyGet(ctx, pid); ferr == nil {
		view = platformView(fresh, pf.Slug)
	}
	return a.forwardProxy(ctx, req, view, fw)
}

// platformAuth signs a person in to (or up on, or out of) the platform from
// its own frontend: _aseman/auth/login {account, password}, register
// {handle, email, password}, logout, me. The session goes into the
// frontend's HttpOnly cookie; the page never sees the token or keys.
// Accounts are the platform's own (auth with its slug).
func (a *API) platformAuth(ctx context.Context, req *network.Request, pf *models.PlatformFrontend, view *proxy.Proxy, cookieName string, acc *account.Account, method, op string) (*network.Response, error) {
	reply := func(status int, body any, cookie string) (*network.Response, error) {
		raw, _ := json.Marshal(body)
		hdr := map[string]string{"Content-Type": "application/json", "Cache-Control": "no-store"}
		if cookie != "" {
			hdr["Set-Cookie"] = cookie
		}
		return &network.Response{Status: status, Body: raw, Header: hdr}, nil
	}
	platform := map[string]any{"id": pf.PlatformID, "slug": pf.Slug, "name": pf.Name}
	if op == "me" {
		if acc == nil {
			return reply(http.StatusOK, map[string]any{"user": nil, "platform": platform}, "")
		}
		return reply(http.StatusOK, map[string]any{"user": map[string]any{"id": acc.ID.String(), "handle": acc.Handle}, "platform": platform}, "")
	}
	if method != http.MethodPost {
		return nil, errs.InvalidArgument("auth/" + op + " takes POST")
	}
	if !sameOrigin(req) {
		return nil, errs.Permission("sign in from the platform's own page")
	}
	if op == "logout" {
		gone := &http.Cookie{Name: cookieName, Value: "", Path: strings.TrimRight(view.GatewayPath(), "/"), MaxAge: -1, HttpOnly: true}
		return reply(http.StatusOK, map[string]any{"ok": true}, gone.String())
	}
	var in map[string]any
	if len(req.Body) > 0 {
		if err := json.Unmarshal(req.Body, &in); err != nil {
			return nil, errs.InvalidArgument("the request body must be a JSON object")
		}
	}
	body := map[string]any{"platform": pf.Slug}
	var keys []string
	switch op {
	case "login":
		keys = []string{"account", "password"}
	case "register":
		keys = []string{"handle", "email", "password"}
	default:
		return nil, errs.NotFound("auth/" + op + ": use login, register, logout or me")
	}
	for _, k := range keys {
		if v, ok := in[k].(string); ok {
			body[k] = v
		}
	}
	var out struct {
		Token     string `json:"token"`
		AccountID string `json:"account_id"`
		Handle    string `json:"handle"`
	}
	if err := a.pageDispatch(ctx, api.Caller{}, "auth", op, body, &out); err != nil {
		return nil, err
	}
	if out.Token == "" {
		return nil, errs.New(errs.CodeUnavailable, "signing in gave no session")
	}
	return reply(http.StatusOK, map[string]any{"user": map[string]any{"id": out.AccountID, "handle": out.Handle}, "platform": platform},
		proxyCookie(req, cookieName, out.Token, view.GatewayPath()))
}

// platformView is a preview as served under a platform's door.
func platformView(p *proxy.Proxy, slug string) *proxy.Proxy {
	view := *p
	view.Path = platformAppPath(slug)
	return &view
}

// platformCaller is who a signed-in platform person's page API calls run as.
func (a *API) platformCaller(ctx context.Context, pfs platformFrontends, p *proxy.Proxy, acc *account.Account, pf *models.PlatformFrontend) (*proxy.Access, error) {
	token, err := pfs.PlatformUserToken(p, acc.ID, pf.PlatformID)
	if err != nil {
		return nil, err
	}
	return pfs.AppCaller(ctx, token)
}
