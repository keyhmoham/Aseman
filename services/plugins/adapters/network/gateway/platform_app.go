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
//   - A computer asleep is woken as the publisher, by anyone, from anywhere:
//     the first request that finds the app's service down starts one wake
//     (shared by everyone who arrives meanwhile, spaces/platform_wake.go);
//     a browser opening a page gets a "waking up" page that reloads itself
//     when the app answers, and other requests a 503 with Retry-After. A
//     client may also wake it before it asks for anything: _aseman/wake
//     (GET or POST, no sign-in) starts the wake and reports how far it got.
//     The platform's own clients (the lightweight Elpian client and the
//     Aseman client) call it whenever they are opened or brought back.
//   - While the frontend is used, each request it serves renews the
//     computer's lease, so it does not fall asleep under its people.

import (
	"context"
	"encoding/json"
	"html"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/internal/plugins/signing"
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
	WakeFrontend(ctx context.Context, id, publisher identity.ID, wait time.Duration) (proxy.Wake, error)
	HoldFrontend(ctx context.Context, id identity.ID) error
}

const (
	// platformWakeWait is how long a request that found the app asleep waits
	// for its computer before it is answered 503 (and asked to retry).
	platformWakeWait = 25 * time.Second
	// platformNavigationWait is that wait for a browser opening a page: it
	// gets the "waking up" page soon instead of a blank tab.
	platformNavigationWait = 3 * time.Second
	// platformHoldEvery is how often traffic renews the computer's lease.
	platformHoldEvery = 20 * time.Second
)

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
		if strings.Trim(page, "/") == "wake" {
			return a.platformWake(ctx, req, pfs, pf, p, method)
		}
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
	if err == nil {
		a.holdPlatform(ctx, pfs, p.ID)
		return resp, nil
	}
	if errs.CodeOf(err) != errs.CodeUnavailable {
		return nil, err
	}
	// The app's computer is asleep (or its service stopped): wake it as the
	// person who published the frontend, and try again once it answers.
	publisher, perr := identity.Parse(pf.Publisher)
	if perr != nil {
		return nil, err
	}
	navigation := isNavigation(req, method)
	wait := platformWakeWait
	if navigation {
		wait = platformNavigationWait
	}
	wake, werr := pfs.WakeFrontend(ctx, p.ID, publisher, wait)
	if werr != nil {
		return nil, errs.New(errs.CodeUnavailable, pf.Name+" is asleep and could not be woken: "+werr.Error())
	}
	if wake.Ready {
		if fresh, ferr := a.Spaces.ProxyGet(ctx, pid); ferr == nil {
			view = platformView(fresh, pf.Slug)
		}
		resp, err := a.forwardProxy(ctx, req, view, fw)
		if err == nil {
			a.holdPlatform(ctx, pfs, p.ID)
		}
		return resp, err
	}
	if navigation {
		return wakingPage(pf, view, wake), nil
	}
	return wakeBusy(pf, wake), nil
}

// holdPlatform renews the lease of the computer behind a frontend that just
// served a request (at most every platformHoldEvery per frontend).
func (a *API) holdPlatform(ctx context.Context, pfs platformFrontends, id identity.ID) {
	now := time.Now()
	if last, ok := a.platformHolds.Load(id); ok && now.Sub(last.(time.Time)) < platformHoldEvery {
		return
	}
	a.platformHolds.Store(id, now)
	if err := pfs.HoldFrontend(ctx, id); err != nil && a.Log != nil {
		a.Log.Debug("platform frontend hold failed", "proxy", id.String(), "error", err)
	}
}

// platformWake answers _aseman/wake: it wakes the frontend's computer (as
// its publisher) unless it is awake, and reports {state, ready, error,
// retry_after_ms}. Anyone may ask, signed in or not: it is what the
// platform's clients call when they are opened. ?wait=<seconds> (at most
// 25) waits for the wake to finish.
func (a *API) platformWake(ctx context.Context, req *network.Request, pfs platformFrontends, pf *models.PlatformFrontend, p *proxy.Proxy, method string) (*network.Response, error) {
	if method != http.MethodGet && method != http.MethodPost {
		return nil, errs.InvalidArgument("_aseman/wake takes GET or POST")
	}
	publisher, err := identity.Parse(pf.Publisher)
	if err != nil {
		return nil, errs.New(errs.CodeUnavailable, pf.Name+"'s frontend has no publisher to wake its computer as; publish it again")
	}
	var wait time.Duration
	if raw := req.Query["wait"]; len(raw) > 0 {
		if n, err := strconv.Atoi(strings.TrimSpace(raw[0])); err == nil && n > 0 {
			wait = min(time.Duration(n)*time.Second, platformWakeWait)
		}
	}
	wake, err := pfs.WakeFrontend(ctx, p.ID, publisher, wait)
	if err != nil {
		return nil, err
	}
	if wake.Ready {
		a.holdPlatform(ctx, pfs, p.ID)
	}
	body, _ := json.Marshal(map[string]any{
		"state": wake.State, "ready": wake.Ready, "error": wake.Error, "retry_after_ms": wake.RetryAfterMs, "since": wake.Since,
		"platform": map[string]any{"id": pf.PlatformID, "slug": pf.Slug, "name": pf.Name},
	})
	return &network.Response{Status: http.StatusOK, Body: body, Header: map[string]string{"Content-Type": "application/json", "Cache-Control": "no-store"}}, nil
}

// isNavigation reports whether a request is a browser opening a page (not
// a script, an image or an API call).
func isNavigation(req *network.Request, method string) bool {
	if method != http.MethodGet {
		return false
	}
	if dest := signing.Header(req.Header, "Sec-Fetch-Dest"); dest != "" {
		return dest == "document" || dest == "iframe"
	}
	return strings.Contains(signing.Header(req.Header, "Accept"), "text/html")
}

func retryAfter(wake proxy.Wake) string {
	ms := wake.RetryAfterMs
	if ms <= 0 {
		ms = 2000
	}
	return strconv.Itoa(max(1, (ms+999)/1000))
}

// wakeBusy answers a request that found the frontend asleep while it wakes.
func wakeBusy(pf *models.PlatformFrontend, wake proxy.Wake) *network.Response {
	message := pf.Name + " is waking up; try again in a few seconds"
	code := "UNAVAILABLE"
	if wake.State == proxy.WakeFailed {
		message = pf.Name + " could not be woken: " + wake.Error
	} else {
		code = "WAKING"
	}
	body, _ := json.Marshal(map[string]any{"error": message, "code": code, "wake": wake})
	return &network.Response{Status: http.StatusServiceUnavailable, Body: body, Header: map[string]string{
		"Content-Type": "application/json", "Cache-Control": "no-store", "Retry-After": retryAfter(wake),
	}}
}

// wakingPage is what a browser opening a sleeping frontend sees: a page that
// asks _aseman/wake until the app answers, then loads it.
func wakingPage(pf *models.PlatformFrontend, view *proxy.Proxy, wake proxy.Wake) *network.Response {
	name := html.EscapeString(pf.Name)
	if name == "" {
		name = html.EscapeString(pf.Slug)
	}
	failed := ""
	if wake.State == proxy.WakeFailed {
		failed = html.EscapeString(wake.Error)
	}
	wakeURL, _ := json.Marshal(view.GatewayPath() + pagePrefix + "wake?wait=20")
	failedJSON, _ := json.Marshal(failed)
	page := `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>` + name + `</title>
<style>
:root{--bg:#f7f7fb;--fg:#1b1b21;--muted:#5d5e6a;--accent:#4f5bd5;--err:#b3261e}
@media (prefers-color-scheme:dark){:root{--bg:#121318;--fg:#e4e1e9;--muted:#a5a5b4;--accent:#b8c3ff;--err:#f2b8b5}}
html,body{height:100%;margin:0}body{display:flex;align-items:center;justify-content:center;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:420px;padding:24px;text-align:center}
h1{font-size:22px;margin:0 0 6px}p{margin:0;color:var(--muted)}
.dot{width:44px;height:44px;margin:0 auto 18px;border-radius:50%;border:4px solid color-mix(in srgb,var(--accent) 25%,transparent);border-top-color:var(--accent);animation:spin 1s linear infinite}
.err .dot{display:none}.err #msg{color:var(--err)}
button{margin-top:18px;padding:10px 20px;border:0;border-radius:999px;background:var(--accent);color:var(--bg);font:inherit;font-weight:600;cursor:pointer;display:none}.err button{display:inline-block}
@keyframes spin{to{transform:rotate(360deg)}}
</style></head><body><main id="box"><div class="dot"></div><h1>` + name + `</h1>
<p id="msg">Waking up… this takes a moment the first time.</p><button id="retry" type="button">Try again</button></main>
<script>
(function(){var url=` + string(wakeURL) + `,failed=` + string(failedJSON) + `,box=document.getElementById('box'),msg=document.getElementById('msg');
function fail(t){box.className='err';msg.textContent='Could not wake up: '+t;}
function poll(){fetch(url,{method:'POST',credentials:'same-origin',cache:'no-store'}).then(function(r){return r.json();}).then(function(w){
if(w.ready){location.reload();return;}if(w.state==='failed'){fail(w.error||'unknown error');return;}setTimeout(poll,w.retry_after_ms||2000);
}).catch(function(){setTimeout(poll,3000);});}
document.getElementById('retry').onclick=function(){box.className='';msg.textContent='Waking up…';poll();};
if(failed){fail(failed);}else{poll();}})();
</script></body></html>`
	return &network.Response{Status: http.StatusServiceUnavailable, Body: []byte(page), Header: map[string]string{
		"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "Retry-After": retryAfter(wake),
	}}
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
