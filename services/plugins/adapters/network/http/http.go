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
	tls    *network.TLSConfig
	mu     sync.Mutex
	cancel context.CancelFunc
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
	handler, params, ok := a.router.Match(method, r.URL.Path)
	if !ok {
		handler, params, ok = a.router.Match(network.MethodCall, r.URL.Path)
		if !ok {
			http.Error(w, `{"error":"route not found"}`, http.StatusNotFound)
			return
		}
	}
	body, _ := io.ReadAll(r.Body)
	_ = r.Body.Close()
	req := &network.Request{
		Method: method,
		Route:  r.URL.Path,
		Path:   r.URL.Path,
		Query:  r.URL.Query(),
		Header: map[string]string{},
		Body:   body,
		Peer:   r.RemoteAddr,
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
	w.WriteHeader(status)
	_, _ = w.Write(resp.Body)
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
	h.Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
	h.Set("Access-Control-Allow-Headers",
		"Content-Type, Authorization, X-Tradera-Nonce, X-Tradera-Timestamp, X-Tradera-Signature, X-Tradera-Node")
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
