// Package websocket implements the network port over WebSocket (JSON messages).
package websocket

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/adapters/base"
	"github.com/aseman/aseman/plugins/adapters/cfg"
	"github.com/aseman/aseman/plugins/adapters/network/ncore"
	"github.com/aseman/aseman/plugins/adapters/network/ports"

	"github.com/gorilla/websocket"
)

// Adapter is the WebSocket network plugin.
type Adapter struct {
	base.Base
	router *ncore.Router
	srv    *http.Server
	addr   string
	path   string
	mu     sync.Mutex
	wg     sync.WaitGroup
	cancel context.CancelFunc
	conns  map[*websocket.Conn]context.Context
	up     websocket.Upgrader
}

// New creates the adapter plugin.
func New(log *logger.Logger) *Adapter {
	return &Adapter{
		Base: base.Base{
			Name:        "websocket",
			Category:    api.CategoryNetwork,
			Version:     "1.0.0",
			Description: "WebSocket protocol adapter",
			Provides:    []string{"network"},
			Log:         log,
		},
		router: ncore.NewRouter(),
		conns:  make(map[*websocket.Conn]context.Context),
		up:     websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }},
	}
}

// Init implements api.Plugin.
func (a *Adapter) Init(ctx context.Context, deps *api.Dependencies) error {
	a.HealthCheck = base.WireHealth(a.Health)

	a.Log = deps.Logger
	c := cfg.Network(deps.Config)
	a.addr = c.Addr
	a.path = c.Path
	if a.path == "" {
		a.path = "/ws"
	}
	return nil
}

// Start implements api.Plugin.
func (a *Adapter) Start(ctx context.Context) error {
	if a.addr == "" {
		return errs.InvalidArgument("websocket adapter requires config.addr (e.g. :9001)")
	}
	return nil
}

// Stop implements api.Plugin.
func (a *Adapter) Stop(ctx context.Context) error { return a.Close(ctx) }

// Name implements network.Network.
func (a *Adapter) Name() string { return "websocket" }

// Open implements network.Network.
func (a *Adapter) Open(ctx context.Context, c network.Config) error {
	a.addr = c.Addr
	if c.Path != "" {
		a.path = c.Path
	}
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
	for conn := range a.conns {
		_ = conn.Close()
	}
	a.mu.Unlock()
	if srv != nil {
		if err := srv.Shutdown(ctx); err != nil {
			return err
		}
	}
	done := make(chan struct{})
	go func() { a.wg.Wait(); close(done) }()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Health implements network.Network.
func (a *Adapter) Health(ctx context.Context) network.Health {
	return network.Health{OK: true, Message: "websocket healthy"}
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
	mux := http.NewServeMux()
	mux.HandleFunc(a.path, a.handleWS)
	a.mu.Lock()
	if ctx.Err() != nil {
		a.mu.Unlock()
		return nil
	}
	ln, err := net.Listen("tcp", a.addr)
	if err != nil {
		a.mu.Unlock()
		return errs.Wrap(errs.CodePlugin, err, "ws listen "+a.addr)
	}
	srv := &http.Server{Addr: a.addr, Handler: mux, ReadHeaderTimeout: 15 * time.Second,
		BaseContext: func(net.Listener) context.Context { return ctx },
	}
	a.srv, a.cancel = srv, cancel
	a.mu.Unlock()
	stop := context.AfterFunc(ctx, func() {
		_ = srv.Close()
		a.mu.Lock()
		for conn, owner := range a.conns {
			if owner.Err() != nil {
				_ = conn.Close()
			}
		}
		a.mu.Unlock()
	})
	defer stop()
	a.Log.Info("websocket serving", "addr", a.addr, "path", a.path)
	err = srv.Serve(ln)
	if err == http.ErrServerClosed {
		return nil
	}
	return errs.Wrap(errs.CodePlugin, err, "ws serve")
}

func (a *Adapter) handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := a.up.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer conn.Close()
	a.mu.Lock()
	if r.Context().Err() != nil {
		a.mu.Unlock()
		return
	}
	a.conns[conn] = r.Context()
	a.wg.Add(1)
	a.mu.Unlock()
	defer func() { a.wg.Done(); a.mu.Lock(); delete(a.conns, conn); a.mu.Unlock() }()
	defer func() {
		if rec := recover(); rec != nil {
			a.Log.Error("websocket handler panic", "error", rec)
		}
	}()
	peer := conn.RemoteAddr().String()
	for {
		_, payload, err := conn.ReadMessage()
		if err != nil {
			return
		}
		req := &network.Request{}
		if err := json.Unmarshal(payload, req); err != nil {
			_ = conn.WriteJSON(&network.Response{Status: 400, Body: []byte(`{"error":"bad frame"}`)})
			continue
		}
		if req.Path == "" {
			req.Path = req.Route
		}
		req.Peer = peer
		handler, params, ok := a.router.Match(req.Method, req.Path)
		if !ok {
			handler, params, ok = a.router.Match(network.MethodCall, req.Path)
		}
		if !ok {
			_ = conn.WriteJSON(&network.Response{Status: 404, Body: []byte(`{"error":"route not found"}`)})
			continue
		}
		if params != nil {
			if req.Header == nil {
				req.Header = map[string]string{}
			}
			b, _ := json.Marshal(params)
			req.Header["x-route-params"] = string(b)
		}
		resp, err := handler(r.Context(), req)
		if err != nil {
			b, _ := json.Marshal(map[string]any{"error": err.Error(), "code": errs.CodeOf(err)})
			resp = &network.Response{Status: 500, Body: b}
		}
		if err := conn.WriteJSON(resp); err != nil {
			return
		}
	}
}

// Call implements network.Network (outbound WebSocket).
func (a *Adapter) Call(ctx context.Context, addr string, req *network.Request) (*network.Response, error) {
	url := "ws://" + addr
	if req.Path != "" {
		url += req.Path
	}
	dialer := websocket.Dialer{HandshakeTimeout: 10 * time.Second}
	conn, _, err := dialer.DialContext(ctx, url, nil)
	if err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "ws dial "+addr)
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	if err := conn.WriteJSON(req); err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "ws write")
	}
	resp := &network.Response{}
	if err := conn.ReadJSON(resp); err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "ws read")
	}
	return resp, nil
}
