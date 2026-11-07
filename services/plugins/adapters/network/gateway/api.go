// Package apihttp implements the HTTP driving adapter: it maps HTTP requests
// onto namespaced actions, authenticates callers, verifies request signatures
// (Ed25519) and renders responses.
package apihttp

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/internal/plugins/signing"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

type Authenticator interface {
	Authenticate(context.Context, string) (*account.Account, error)
}
type FileSpaces interface {
	GetFile(context.Context, identity.ID) (*filedata.File, error)
	CanReadFile(context.Context, identity.ID, identity.ID) error
	ReadFileBytes(context.Context, *filedata.File) ([]byte, error)
	ProxyGet(context.Context, identity.ID) (*proxy.Proxy, error)
	SpaceMembership(context.Context, identity.ID, identity.ID) (*membership.Membership, error)
}

// API bridges the network protocol to the action router.
type API struct {
	K      Host
	Auth   Authenticator
	Log    *logger.Logger
	Spaces FileSpaces
	replay *signing.ReplayGuard
	// pageActions runs the actions a preview's page API calls (tests set
	// it; nil is the kernel's router).
	pageActions func(context.Context, string, string, *api.ActionRequest) (*api.ActionResponse, error)
	// platformHolds is when each platform frontend last renewed its
	// computer's lease (platform_app.go), by preview id.
	platformHolds sync.Map
	// publicOrigins is the origin each person was last noted at
	// (public_origin.go), by account id.
	publicOrigins sync.Map
}

// New builds the API gateway.
func New(k Host, a Authenticator, log *logger.Logger) *API {
	return &API{K: k, Auth: a, Log: log.Named("api"), replay: signing.NewReplayGuard()}
}

// Register binds the gateway to a network adapter.
func (a *API) Register(net network.Network) error {
	if err := net.Handle(network.MethodCall, "/v1/*", a.dispatch); err != nil {
		return err
	}
	// Raw file streaming endpoint: GET /v1/files/{id}/content serves a stored
	// file's bytes with its Content-Type so the client can preview media
	// (photos, gifs, audio, voice, video) directly from a URL/player instead of
	// round-tripping base64 through the JSON action protocol.
	if err := net.Handle(network.MethodGet, "/v1/files/{id}/content", a.fileContent); err != nil {
		return err
	}
	// Gateway proxy: GET /v1/proxy/{id}/* tunnels HTTP traffic to a port of the
	// space's Modal sandbox (e.g. a deployed landing page) for the room's users.
	if err := net.Handle(network.MethodGet, "/v1/proxy/{id}/*", a.proxyServe); err != nil {
		return err
	}
	// A preview is an app, not a picture of one: its forms and API calls
	// (POST and friends) go through as well.
	for _, method := range []network.Method{network.MethodPost, network.MethodPut, network.MethodPatch, network.MethodDelete} {
		if err := net.Handle(method, "/v1/proxy/{id}/*", a.proxyServe); err != nil {
			return err
		}
	}
	// Framework base-path links commonly use the canonical root without a slash.
	if err := net.Handle(network.MethodGet, "/v1/proxy/{id}", a.proxyServe); err != nil {
		return err
	}
	// A platform's frontend: an app built in a space, served to the
	// platform's people (platform_app.go).
	for _, method := range []network.Method{network.MethodGet, network.MethodPost, network.MethodPut, network.MethodPatch, network.MethodDelete} {
		if err := net.Handle(method, "/v1/platforms/{slug}/app/*", a.platformServe); err != nil {
			return err
		}
	}
	if err := net.Handle(network.MethodGet, "/v1/platforms/{slug}/app", a.platformServe); err != nil {
		return err
	}
	// A platform's own Android app, for anyone to install (platform_client.go).
	if err := net.Handle(network.MethodGet, "/v1/platforms/{slug}/client/{file}", a.platformClientDownload); err != nil {
		return err
	}
	// App servers in a sandbox use the space's agents and apps (app_api.go).
	for _, method := range []network.Method{network.MethodGet, network.MethodPost} {
		if err := net.Handle(method, "/appapi/v1/*", a.appAPI); err != nil {
			return err
		}
	}
	if err := net.Handle(network.MethodGet, "/healthz", a.health); err != nil {
		return err
	}
	if err := net.Handle(network.MethodCall, "/healthz", a.health); err != nil {
		return err
	}
	return nil
}

// health is a liveness probe.
func (a *API) health(ctx context.Context, req *network.Request) (*network.Response, error) {
	body, _ := json.Marshal(map[string]any{"ok": true, "node": a.K.NodeID().String()})
	return &network.Response{Status: 200, Body: body}, nil
}

// fileContent streams a stored file's raw bytes (GET /v1/files/{id}/content).
// The caller must authenticate with a bearer token and hold room.read in the
// space/room the file belongs to. This powers media previews and downloads in
// the client.
func (a *API) fileContent(ctx context.Context, req *network.Request) (*network.Response, error) {
	params := map[string]string{}
	if raw := req.Header["x-route-params"]; raw != "" {
		_ = json.Unmarshal([]byte(raw), &params)
	}
	fileID, err := identity.Parse(params["id"])
	if err != nil {
		return nil, errs.InvalidArgument("invalid file id")
	}
	if a.Spaces == nil {
		return nil, errs.New(errs.CodeUnavailable, "spaces service unavailable")
	}
	// Bearer-token authentication (mirrors dispatch; raw GET routes can't use
	// the body-signing path since there is no JSON payload). The token may come
	// from the Authorization header or, for media elements on the web that
	// cannot set custom headers, the ?token= query parameter.
	token := signing.Header(req.Header, "Authorization")
	token = strings.TrimPrefix(token, "Bearer ")
	if token == "" && len(req.Query["token"]) > 0 {
		token = req.Query["token"][0]
	}
	if token == "" {
		return nil, errs.Unauthenticated("authentication required")
	}
	acc, err := a.Auth.Authenticate(ctx, token)
	if err != nil {
		return nil, err
	}
	if acc == nil || acc.Kind == account.KindBot {
		// Bots authenticate with their VM secrets, not a user bearer token.
		return nil, errs.Unauthenticated("authentication required")
	}
	file, err := a.Spaces.GetFile(ctx, fileID)
	if err != nil {
		return nil, err
	}
	if err := a.Spaces.CanReadFile(ctx, file.ID, acc.ID); err != nil {
		return nil, err
	}
	data, err := a.Spaces.ReadFileBytes(ctx, file)
	if err != nil {
		return nil, err
	}
	ctype := file.Mime
	if ctype == "" {
		ctype = http.DetectContentType(data)
	}
	disp := "inline"
	if strings.HasPrefix(ctype, "application/") && !strings.Contains(ctype, "pdf") {
		disp = "attachment"
	}
	filename := file.Name
	if filename == "" {
		filename = file.ID.String()
	}
	return &network.Response{
		Status: http.StatusOK,
		Header: map[string]string{
			"Content-Type":                ctype,
			"Content-Disposition":         fmt.Sprintf("%s; filename=%q", disp, filename),
			"Cache-Control":               "private, max-age=3600",
			"Access-Control-Allow-Origin": "*",
		},
		Body: data,
	}, nil
}

// proxyServe reverse-proxies GET traffic from the gateway (/v1/proxy/{id}/*) to
// the target port of the space's Modal sandbox. The caller must authenticate and
// be a member of the proxy's space; the sandbox credential is never exposed.
func (a *API) proxyServe(ctx context.Context, req *network.Request) (*network.Response, error) {
	params := map[string]string{}
	if raw := req.Header["x-route-params"]; raw != "" {
		_ = json.Unmarshal([]byte(raw), &params)
	}
	id, err := identity.Parse(params["id"])
	if err != nil {
		return nil, errs.InvalidArgument("invalid proxy id")
	}
	if a.Spaces == nil {
		return nil, errs.New(errs.CodeUnavailable, "spaces service unavailable")
	}
	p, err := a.Spaces.ProxyGet(ctx, id)
	if err != nil {
		return nil, err
	}
	// Sub-resources (css/js/img) are requested by the browser WITHOUT the ?token
	// query (relative URLs don't inherit it). After the first authenticated load
	// we set a path-scoped auth cookie, so subsequent asset requests are allowed.
	cookieName := "oc_proxy_" + id.String()
	token, fromCookie := requestToken(req, cookieName)
	if token == "" {
		return nil, errs.Unauthenticated("authentication required")
	}
	method := string(req.Method)
	if method == "" || req.Method == network.MethodCall {
		method = http.MethodGet
	}
	// A request that changes something and is carried by the cookie must come
	// from the preview's own page: another site must not be able to submit to
	// a person's preview with their sign-in.
	if method != http.MethodGet && fromCookie && !sameOrigin(req) {
		return nil, errs.Permission("this request did not come from the preview itself")
	}
	acc, err := a.Auth.Authenticate(ctx, token)
	if err != nil {
		return nil, err
	}
	if acc == nil || acc.Kind == account.KindBot {
		return nil, errs.Unauthenticated("authentication required")
	}
	// A cookie is a credential, never proof of authorization. Recheck the
	// session and membership on every asset/route request, including revocation.
	if _, err := a.Spaces.SpaceMembership(ctx, p.SpaceID, acc.ID); err != nil {
		return nil, errs.Permission("not a member of the proxy's space")
	}

	rest := params["*"]
	// The kit and the page's Aseman API are the gateway's own, never the
	// sandbox's (proxy_page.go).
	if page, ok := strings.CutPrefix(strings.TrimLeft(rest, "/"), pagePrefix); ok {
		return a.proxyPage(ctx, req, p, acc, method, page)
	}
	fw := proxyForward{
		rest: rest, method: method,
		headers: a.appHeaders(p, acc.ID, acc.Handle),
		socket: func() error {
			access, ok := a.Spaces.(interface {
				CanProxy(context.Context, identity.ID, identity.ID, bool) error
			})
			if !ok {
				return errs.Permission("duplex proxy authorization unavailable")
			}
			return access.CanProxy(ctx, p.ID, acc.ID, true)
		},
	}
	// Only the first (authenticated) load needs the token; the cookie then
	// authorizes the page's css/js/images on the same proxy path.
	if !fromCookie {
		fw.cookie = proxyCookie(req, cookieName, token, p.GatewayPath())
	}
	return a.forwardProxy(ctx, req, p, fw)
}

// requestToken is the session a preview request carries: the Authorization
// header, the ?token= of a first load, or the preview's cookie after it.
func requestToken(req *network.Request, cookieName string) (token string, fromCookie bool) {
	token = strings.TrimPrefix(signing.Header(req.Header, "Authorization"), "Bearer ")
	if token == "" && len(req.Query["token"]) > 0 {
		token = req.Query["token"][0]
	}
	if token != "" {
		return token, false
	}
	cookie := (&http.Request{Header: http.Header{"Cookie": []string{signing.Header(req.Header, "Cookie")}}})
	if value, err := cookie.Cookie(cookieName); err == nil {
		if decoded, err := base64.RawURLEncoding.DecodeString(value.Value); err == nil && len(decoded) > 0 {
			return string(decoded), true
		}
	}
	return "", false
}

// sameOrigin reports whether a request came from the page's own origin (or
// from a client that does not say).
func sameOrigin(req *network.Request) bool {
	site := signing.Header(req.Header, "Sec-Fetch-Site")
	return site == "" || site == "same-origin"
}

// proxyForward is how one request is forwarded to a preview's service.
type proxyForward struct {
	// rest is the path after the gateway prefix; method the HTTP method.
	rest, method string
	// headers are the app headers for the person using it (app_api.go).
	headers map[string]string
	// cookie is the Set-Cookie value of a first authenticated load ("" none).
	cookie string
	// socket authorizes a WebSocket upgrade.
	socket func() error
}

// proxyCookie is the path-scoped cookie that authorizes a preview page's own
// assets after its first, token-carrying, load.
func proxyCookie(req *network.Request, name, token, gatewayPath string) string {
	cookie := &http.Cookie{Name: name, Value: base64.RawURLEncoding.EncodeToString([]byte(token)), Path: strings.TrimRight(gatewayPath, "/"), SameSite: http.SameSiteLaxMode, HttpOnly: true}
	// The app shows a preview in a frame, and the app may be on another
	// site than this node (a different domain, a local build). A Lax
	// cookie is not sent for a framed page's css and scripts there, which
	// left the page unstyled. Over HTTPS the cookie is therefore usable in
	// a frame, and partitioned: it exists only inside the site that
	// framed it, so no other site can ride on it.
	if strings.EqualFold(signing.Header(req.Header, "X-Forwarded-Proto"), "https") {
		cookie.SameSite, cookie.Secure, cookie.Partitioned = http.SameSiteNoneMode, true, true
	}
	return cookie.String()
}

// forwardProxy sends a request on to the preview's service and answers with
// its response, rewritten to stay under the preview's gateway path.
func (a *API) forwardProxy(ctx context.Context, req *network.Request, p *proxy.Proxy, fw proxyForward) (*network.Response, error) {
	rest, method := fw.rest, fw.method
	upstream := strings.TrimRight(p.TargetURL, "/")
	if rest != "" {
		upstream += "/" + strings.TrimLeft(rest, "/")
	} else if p.PreservesPath() && (strings.HasSuffix(req.Path, "/") || (req.Path == "" && strings.HasSuffix(p.TargetURL, "/"))) {
		// Root slash semantics belong to the application; stripping it can
		// redirect back to this exact gateway URL indefinitely.
		upstream += "/"
	}
	u, err := url.Parse(upstream)
	if err != nil {
		return nil, errs.InvalidArgument("invalid proxy target")
	}
	if len(req.Query) > 0 {
		query := url.Values{}
		for key, values := range req.Query {
			// Gateway-only: session token and the app's theme/embed hints
			// must not reach upstream. Many sandbox apps match request.url
			// exactly ("/"); forwarding ?aseman_theme=… made them 404
			// "Not found" in mobile desk sheets.
			if key == "token" || strings.HasPrefix(key, "aseman_") {
				continue
			}
			query[key] = values
		}
		u.RawQuery = query.Encode()
	}
	if strings.EqualFold(signing.Header(req.Header, "Upgrade"), "websocket") {
		if fw.socket == nil {
			return nil, errs.Permission("duplex proxy authorization unavailable")
		}
		if err := fw.socket(); err != nil {
			return nil, err
		}
		if u.Scheme == "https" {
			u.Scheme = "wss"
		} else {
			u.Scheme = "ws"
		}
		tunnelHeader := map[string]string{"Authorization": "Bearer " + p.Token}
		for k, v := range fw.headers {
			tunnelHeader[k] = v
		}
		return &network.Response{Status: 101, Tunnel: &network.Tunnel{Protocol: "websocket", Target: u.String(), Header: tunnelHeader}}, nil
	}
	var payload io.Reader
	if method != http.MethodGet && len(req.Body) > 0 {
		payload = bytes.NewReader(req.Body)
	}
	upReq, err := http.NewRequestWithContext(ctx, method, u.String(), payload)
	if err != nil {
		return nil, errs.Wrap(errs.CodeInternal, err, "proxy request")
	}
	upReq.Header.Set("Authorization", "Bearer "+p.Token)
	for _, name := range []string{"Accept", "Content-Type", "RSC", "Next-Router-State-Tree", "Next-Router-Prefetch", "Next-Router-Segment-Prefetch", "Next-Url", "Next-Action"} {
		if value := signing.Header(req.Header, name); value != "" {
			upReq.Header.Set(name, value)
		}
	}
	upReq.Header.Set("X-Forwarded-Prefix", strings.TrimRight(p.GatewayPath(), "/"))
	// Who is using the app, and the token its server uses the space's agents
	// and apps for them with (billed to them; app_api.go). Never taken from
	// the browser: these are set here only.
	for k, v := range fw.headers {
		upReq.Header.Set(k, v)
	}
	resp, err := proxyClient.Do(upReq)
	if err != nil {
		return nil, errs.Wrap(errs.CodeUnavailable, err, "proxy upstream")
	}
	// What the gateway does not rewrite (a game's engine and packs, models,
	// images, media) streams through as it comes: any size, however long the
	// download takes on a slow connection.
	if ctype := resp.Header.Get("Content-Type"); ctype != "" && !proxyRewritable(ctype) {
		return a.streamProxy(resp, p, fw, ctype), nil
	}
	// Pages, scripts and styles are read whole to be rewritten, within limits.
	stop := time.AfterFunc(proxyReadTimeout, func() { resp.Body.Close() })
	body, err := io.ReadAll(io.LimitReader(resp.Body, (32<<20)+1))
	stop.Stop()
	resp.Body.Close()
	if err != nil {
		return nil, errs.Wrap(errs.CodeUnavailable, err, "read proxy response")
	}
	if len(body) > 32<<20 {
		return nil, errs.New(errs.CodeUnavailable, "proxy response exceeds 32 MiB")
	}
	ctype := resp.Header.Get("Content-Type")
	if ctype == "" {
		ctype = http.DetectContentType(body)
	}
	// Rewrite absolute asset paths so pages built for the site root (e.g. a
	// Next.js app that references /_next/static/...) keep loading through the
	// proxy: /_next/... becomes /v1/proxy/{id}/_next/... so the browser asks the
	// gateway, which forwards them to the sandbox.
	if !p.PreservesPath() {
		body = rewriteProxyAssets(body, ctype, p.GatewayPath())
		body = rewriteProxyLinks(body, ctype, p.GatewayPath())
	}
	// Keep the page's own navigation (links, forms, client-side routers,
	// fetches) under the proxy prefix instead of the Aseman app's routes.
	// It is a no-op for an app already built for the prefix.
	body = injectProxyShim(body, ctype, p.GatewayPath())
	hdr := map[string]string{
		"Content-Type":                ctype,
		"Access-Control-Allow-Origin": "*",
		"Cache-Control":               "no-store",
	}
	if vary := resp.Header.Get("Vary"); vary != "" {
		hdr["Vary"] = vary
	}
	if location := resp.Header.Get("Location"); location != "" {
		if strings.HasPrefix(location, "/") && !strings.HasPrefix(location, "//") && !strings.HasPrefix(location, p.GatewayPath()) && strings.TrimRight(location, "/") != strings.TrimRight(p.GatewayPath(), "/") {
			location = p.GatewayPath() + strings.TrimLeft(location, "/")
		}
		hdr["Location"] = location
	}
	if fw.cookie != "" {
		hdr["Set-Cookie"] = fw.cookie
	}
	return &network.Response{
		Status: resp.StatusCode,
		Header: hdr,
		Body:   body,
	}, nil
}

// proxyReadTimeout bounds waiting for an upstream's answer, and reading one
// the gateway buffers (a streamed one takes as long as it takes).
const proxyReadTimeout = 120 * time.Second

// proxyClient forwards preview requests; it never follows redirects (the
// page's own Location goes back to the browser, rewritten).
var proxyClient = &http.Client{
	Transport: func() http.RoundTripper {
		t := http.DefaultTransport.(*http.Transport).Clone()
		t.ResponseHeaderTimeout = proxyReadTimeout
		return t
	}(),
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

// proxyRewritable reports whether the gateway rewrites a response of this
// type (and so must read it whole): HTML, CSS, JavaScript, JSON and text.
func proxyRewritable(ctype string) bool {
	c := strings.ToLower(ctype)
	return strings.Contains(c, "html") || strings.Contains(c, "css") || strings.Contains(c, "javascript") ||
		strings.Contains(c, "json") || strings.HasPrefix(c, "text/")
}

// streamProxy answers with an upstream response as it arrives.
func (a *API) streamProxy(resp *http.Response, p *proxy.Proxy, fw proxyForward, ctype string) *network.Response {
	hdr := map[string]string{
		"Content-Type":                ctype,
		"Access-Control-Allow-Origin": "*",
		"Cache-Control":               "no-store",
	}
	if cc := resp.Header.Get("Cache-Control"); cc != "" {
		hdr["Cache-Control"] = cc
	}
	for _, name := range []string{"Content-Length", "ETag", "Last-Modified", "Vary"} {
		if v := resp.Header.Get(name); v != "" {
			hdr[name] = v
		}
	}
	if location := resp.Header.Get("Location"); location != "" {
		if strings.HasPrefix(location, "/") && !strings.HasPrefix(location, "//") && !strings.HasPrefix(location, p.GatewayPath()) {
			location = p.GatewayPath() + strings.TrimLeft(location, "/")
		}
		hdr["Location"] = location
	}
	if fw.cookie != "" {
		hdr["Set-Cookie"] = fw.cookie
	}
	return &network.Response{
		Status: resp.StatusCode,
		Header: hdr,
		Stream: func(_ context.Context, w io.Writer) error {
			defer resp.Body.Close()
			_, err := io.Copy(w, resp.Body)
			return err
		},
	}
}

// rewriteProxyAssets rewrites absolute root asset references (e.g. /_next/...,
// /styles.css) inside served HTML/CSS/JS so they resolve through the proxy
// prefix (/v1/proxy/{id}/...). Relative references are left untouched.
func rewriteProxyAssets(body []byte, ctype, prefix string) []byte {
	if !strings.Contains(ctype, "html") && !strings.Contains(ctype, "css") &&
		!strings.Contains(ctype, "javascript") && !strings.Contains(ctype, "json") &&
		!strings.Contains(ctype, "text") {
		return body
	}
	// Prefix absolute asset references: "/_next/static/...", '/_next/...',
	// url(/_next/...), and other root-relative paths starting with /_.
	replacer := strings.NewReplacer(
		`"/_next/`, `"`+prefix+`_next/`,
		`'/_next/`, `'`+prefix+`_next/`,
		`(/_next/`, `(`+prefix+`_next/`,
		` /_next/`, ` `+prefix+`_next/`,
		`=/_next/`, `=`+prefix+`_next/`,
		`:/_next/`, `:`+prefix+`_next/`,
	)
	return []byte(replacer.Replace(string(body)))
}

// dispatch routes a normalized request to a namespaced action.
func (a *API) dispatch(ctx context.Context, req *network.Request) (*network.Response, error) {
	ns, name, ok := parsePath(req.Path)
	if !ok {
		return nil, errs.NotFound("no such route " + req.Path)
	}
	acc, actionReq, err := a.authenticate(req)
	if err != nil {
		return a.errorResponse(err), nil
	}
	if acc != nil && acc.PublicKey != "" {
		if err := a.verifySignature(acc, req); err != nil {
			return a.errorResponse(err), nil
		}
	}
	actionReq.Origin = a.K.NodeID()
	actionReq.Body = req.Body
	if acc != nil && acc.Kind != account.KindBot {
		a.notePublicOrigin(acc.ID, req)
	}
	var resp *api.ActionResponse
	if ns == "_node" {
		resp, err = a.K.Control(ctx, name, actionReq)
	} else {
		resp, err = a.K.Actions().Dispatch(ctx, ns, name, actionReq)
	}
	if err != nil {
		return a.errorResponse(err), nil
	}
	return &network.Response{Status: resp.Status, Body: resp.Body}, nil
}

// authenticate resolves the bearer token and builds the action request.
func (a *API) authenticate(req *network.Request) (*account.Account, *api.ActionRequest, error) {
	ar := &api.ActionRequest{}
	token := signing.Header(req.Header, "Authorization")
	if strings.HasPrefix(token, "Bearer ") {
		token = strings.TrimPrefix(token, "Bearer ")
	} else {
		token = ""
	}
	if token == "" {
		ar.Meta = map[string]any{}
		return nil, ar, nil
	}
	var acc *account.Account
	var err error
	namespace, _, _ := parsePath(req.Path)
	if namespace == "_node" {
		acc, err = a.K.Authenticate(context.Background(), token, true)
	} else {
		acc, err = a.Auth.Authenticate(context.Background(), token)
	}
	if err != nil {
		return nil, nil, err
	}
	ar.Caller = api.Caller{ID: acc.ID, Kind: string(acc.Kind)}
	ar.Meta = map[string]any{"token": token, "handle": acc.Handle}
	return acc, ar, nil
}

// verifySignature checks the Ed25519 signature over the canonical request
// payload and rejects replays.
func (a *API) verifySignature(acc *account.Account, req *network.Request) error {
	return a.replay.VerifyRequest(acc.PublicKey, acc.ID.String(),
		string(req.Method), req.Path, req.Header, req.Body)
}

// errorResponse renders a coded error as JSON.
func (a *API) errorResponse(err error) *network.Response {
	b, _ := json.Marshal(map[string]any{"error": err.Error(), "code": errs.CodeOf(err)})
	status := helper.StatusOf(err)
	return &network.Response{Status: status, Body: b}
}

// parsePath extracts namespace and action from /v1/{ns}/{action}.
func parsePath(p string) (string, string, bool) {
	segs := strings.Split(strings.TrimPrefix(p, "/"), "/")
	if len(segs) < 3 || segs[0] != "v1" {
		return "", "", false
	}
	return segs[1], segs[2], true
}

// Host is the fixed routing and maintenance surface required by the gateway.
type Host interface {
	api.Kernel
	Control(context.Context, string, *api.ActionRequest) (*api.ActionResponse, error)
	Authenticate(context.Context, string, bool) (*account.Account, error)
}
