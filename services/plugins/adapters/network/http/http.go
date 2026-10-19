// Package http implements the network port over HTTP/1.1 (default protocol).
package http

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/adapters/base"
	"github.com/tradera/tradera/plugins/adapters/cfg"
	"github.com/tradera/tradera/plugins/adapters/network/ncore"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
)

// Adapter is the HTTP network plugin.
type Adapter struct {
	base.Base
	router *ncore.Router
	srv    *http.Server
	addr   string
	// developerHost is the host of the developer API door (api.example.com):
	// requests addressed to it reach only the developer routes, and its
	// /v1/... is the developer API (see the developer namespace).
	developerHost string
	tls           *network.TLSConfig
	mu            sync.Mutex
	cancel        context.CancelFunc
}

// New creates the adapter plugin.
func New(log *logger.Logger) *Adapter {
	return &Adapter{
		Base: base.Base{
			Name:        "http",
			Category:    api.CategoryNetwork,
			Version:     "1.0.0",
			Description: "HTTP/1.1 protocol adapter (default)",
			Provides:    []string{"network"},
			Log:         log,
		},
		router: ncore.NewRouter(),
	}
}

// Init implements api.Plugin.
func (a *Adapter) Init(ctx context.Context, deps *api.Dependencies) error {
	a.HealthCheck = base.WireHealth(a.Health)

	a.Log = deps.Logger
	c := cfg.Network(deps.Config)
	a.addr = c.Addr
	a.tls = c.TLS
	a.developerHost = normalizeHost(c.Options["developer_host"])
	return nil
}

// Start implements api.Plugin.
func (a *Adapter) Start(ctx context.Context) error {
	if a.addr == "" {
		return errs.InvalidArgument("http adapter requires config.addr (e.g. :8080)")
	}
	return nil
}

// Stop implements api.Plugin.
func (a *Adapter) Stop(ctx context.Context) error { return a.Close(ctx) }

// Name implements network.Network.
func (a *Adapter) Name() string { return "http" }

// Open implements network.Network.
func (a *Adapter) Open(ctx context.Context, c network.Config) error {
	a.addr = c.Addr
	a.tls = c.TLS
	a.developerHost = normalizeHost(c.Options["developer_host"])
	return nil
}

// Close implements network.Network.
func (a *Adapter) Close(ctx context.Context) error {
	a.mu.Lock()
	if a.cancel != nil {
		a.cancel()
	}
	srv := a.srv
	a.srv = nil
	a.mu.Unlock()
	if srv != nil {
		return srv.Shutdown(ctx)
	}
	return nil
}

// Health implements network.Network.
func (a *Adapter) Health(ctx context.Context) network.Health {
	return network.Health{OK: true, Message: "http healthy"}
}

// Handle implements network.Network.
func (a *Adapter) Handle(method network.Method, route string, h network.Handler) error {
	return a.router.Handle(method, route, h)
}

// Unhandle implements network.Network.
func (a *Adapter) Unhandle(method network.Method, route string) error {
	return a.router.Unhandle(method, route)
}

// Serve implements network.Network (blocking).
func (a *Adapter) Serve(ctx context.Context) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	if a.addr == "" {
		return errs.InvalidArgument("http adapter has no listen address")
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/", a.dispatch)
	a.mu.Lock()
	if ctx.Err() != nil {
		a.mu.Unlock()
		return nil
	}
	srv := &http.Server{
		Addr: a.addr, Handler: mux, ReadHeaderTimeout: 15 * time.Second,
		BaseContext: func(net.Listener) context.Context { return ctx },
	}
	ln, err := net.Listen("tcp", a.addr)
	if err != nil {
		a.mu.Unlock()
		return errs.Wrap(errs.CodePlugin, err, "listen "+a.addr)
	}
	a.srv, a.cancel = srv, cancel
	a.mu.Unlock()
	stop := context.AfterFunc(ctx, func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			_ = srv.Close()
		}
	})
	defer stop()
	a.Log.Info("http serving", "addr", a.addr)
	if a.tls != nil && a.tls.CertFile != "" {
		err = srv.ServeTLS(ln, a.tls.CertFile, a.tls.KeyFile)
	} else {
		err = srv.Serve(ln)
	}
	if err == http.ErrServerClosed {
		return nil
	}
	return errs.Wrap(errs.CodePlugin, err, "http serve")
}

func (a *Adapter) dispatch(w http.ResponseWriter, r *http.Request) {
	defer func() {
		if rec := recover(); rec != nil {
			a.Log.Error("http handler panic", "error", rec, "stack", string(debug.Stack()))
			_ = writeJSON(w, http.StatusInternalServerError, map[string]any{
				"error": "internal handler panic", "code": errs.CodeInternal,
			})
		}
	}()
	// CORS: the Flutter web client runs on a different origin and must be able
	// to send signed JSON requests (and read the responses). Preflights are
	// answered here; actual responses carry the allow headers.
	setCORS(w)
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	method := network.Method(r.Method)
	host := requestHost(r)
	path, ok := a.routePath(host, r.URL.Path)
	if !ok {
		http.Error(w, `{"error":"route not found"}`, http.StatusNotFound)
		return
	}
	handler, params, ok := a.router.Match(method, path)
	if !ok {
		handler, params, ok = a.router.Match(network.MethodCall, path)
		if !ok {
			http.Error(w, `{"error":"route not found"}`, http.StatusNotFound)
			return
		}
	}
	body, _ := io.ReadAll(r.Body)
	_ = r.Body.Close()
	req := &network.Request{
		Method: method,
		Route:  path,
		Path:   path,
		Query:  r.URL.Query(),
		Header: map[string]string{},
		Body:   body,
		Peer:   r.RemoteAddr,
		Host:   host,
	}
	for k, v := range r.Header {
		if len(v) > 0 {
			req.Header[k] = v[0]
		}
	}
	if params != nil {
		req.Header["x-route-params"] = mustJSON(params)
	}
	resp, err := handler(r.Context(), req)
	if err != nil {
		status := errStatus(err)
		_ = writeJSON(w, status, map[string]any{"error": err.Error(), "code": errs.CodeOf(err)})
		return
	}
	if resp.Tunnel != nil {
		a.serveTunnel(w, r, resp.Tunnel)
		return
	}
	status := resp.Status
	if status == 0 {
		status = http.StatusOK
	}
	for k, v := range resp.Header {
		w.Header().Set(k, v)
	}
	if resp.Stream != nil {
		w.Header().Set("X-Accel-Buffering", "no") // a proxy must not hold the events back
		w.WriteHeader(status)
		fw := &flushWriter{w: w}
		if f, ok := w.(http.Flusher); ok {
			fw.f = f
			f.Flush()
		}
		if err := resp.Stream(r.Context(), fw); err != nil {
			a.Log.Warn("http stream ended", "path", path, "error", err)
		}
		return
	}
	w.WriteHeader(status)
	_, _ = w.Write(resp.Body)
}

// developerPrefix is where the developer namespace's routes live in the router.
// The developer host's /v1/... is mapped onto it, so the same path never means
// two things: /v1/chat/completions on the developer host, /v1/{ns}/{action} on
// the node's own.
const developerPrefix = "/dev"

// routePath maps the requested path to the router's. On the developer host
// only the developer API is reachable (and a health probe); anywhere else the
// developer prefix is not served, so that door has exactly one address.
func (a *Adapter) routePath(host, path string) (string, bool) {
	if a.developerHost != "" && host == a.developerHost {
		switch {
		case path == "/healthz":
			return path, true
		case path == "/v1" || strings.HasPrefix(path, "/v1/"):
			return developerPrefix + path, true
		}
		return "", false
	}
	if a.developerHost != "" && (path == developerPrefix || strings.HasPrefix(path, developerPrefix+"/")) {
		return "", false
	}
	return path, true
}

// requestHost is the host a request was addressed to, without a port. A
// forwarded host is believed: the node sits behind the deployment's proxy.
func requestHost(r *http.Request) string {
	if forwarded := r.Header.Get("X-Forwarded-Host"); forwarded != "" {
		return normalizeHost(strings.Split(forwarded, ",")[0])
	}
	return normalizeHost(r.Host)
}

func normalizeHost(host string) string {
	host = strings.ToLower(strings.TrimSpace(host))
	if i := strings.LastIndex(host, ":"); i > 0 && !strings.Contains(host[i:], "]") {
		host = host[:i]
	}
	return host
}

// flushWriter sends every write to the caller at once.
type flushWriter struct {
	w http.ResponseWriter
	f http.Flusher
}

func (f *flushWriter) Write(p []byte) (int, error) {
	n, err := f.w.Write(p)
	if f.f != nil {
		f.f.Flush()
	}
	return n, err
}

// Call implements network.Network (outbound HTTP).
func (a *Adapter) Call(ctx context.Context, addr string, req *network.Request) (*network.Response, error) {
	url := addr + req.Path
	if len(req.Query) > 0 {
		url += "?" + req.Query.Encode()
	}
	httpReq, err := http.NewRequestWithContext(ctx, string(req.Method), url, bytes.NewReader(req.Body))
	if err != nil {
		return nil, errs.Wrap(errs.CodePlugin, err, "build request")
	}
	for k, v := range req.Header {
		httpReq.Header.Set(k, v)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 30 * time.Second}
	if req.Method == "https" {
		client.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
	}
	resp, err := client.Do(httpReq)
	if err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "http call "+addr)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, errs.Wrap(errs.CodePlugin, err, "read response")
	}
	return &network.Response{Status: resp.StatusCode, Body: b}, nil
}

func errStatus(err error) int {
	switch errs.CodeOf(err) {
	case errs.CodeNotFound:
		return http.StatusNotFound
	case errs.CodeAlreadyExists, errs.CodeConflict:
		return http.StatusConflict
	case errs.CodeInvalidArgument:
		return http.StatusBadRequest
	case errs.CodeUnauthenticated:
		return http.StatusUnauthorized
	case errs.CodePermission:
		return http.StatusForbidden
	default:
		return http.StatusInternalServerError
	}
}

// setCORS permits cross-origin calls from the Flutter web client. The gateway
// only ever speaks JSON and the custom signing headers below are required, so
// the allow-list is intentionally narrow.
func setCORS(w http.ResponseWriter) {
	h := w.Header()
	h.Set("Access-Control-Allow-Origin", "*")
	h.Set("Access-Control-Allow-Methods", "POST, GET, PUT, PATCH, DELETE, OPTIONS")
	h.Set("Access-Control-Allow-Headers",
		"Content-Type, Authorization, X-Tradera-Nonce, X-Tradera-Timestamp, X-Tradera-Signature, X-Tradera-Node")
	h.Set("Access-Control-Expose-Headers", "X-Tradera-Model, X-Tradera-Cost, X-Tradera-Request-Id, X-RateLimit-Limit, X-RateLimit-Remaining, Retry-After")
	h.Set("Access-Control-Max-Age", "600")
}

func writeJSON(w http.ResponseWriter, status int, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(b)
	return nil
}

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
