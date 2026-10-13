// Package tcp implements the network port over a custom length-prefixed JSON
// frame protocol. Each frame is: [4-byte big-endian length][JSON request].
package tcp

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
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

// Adapter is the TCP network plugin.
type Adapter struct {
	base.Base
	router *ncore.Router
	ln     net.Listener
	addr   string
	wg     sync.WaitGroup
	mu     sync.Mutex
	cancel context.CancelFunc
	conns  map[net.Conn]context.Context
}

// New creates the adapter plugin.
func New(log *logger.Logger) *Adapter {
	return &Adapter{
		Base: base.Base{
			Name:        "tcp",
			Category:    api.CategoryNetwork,
			Version:     "1.0.0",
			Description: "Custom JSON-framed TCP protocol adapter",
			Provides:    []string{"network"},
			Log:         log,
		},
		router: ncore.NewRouter(),
		conns:  make(map[net.Conn]context.Context),
	}
}

// Init implements api.Plugin.
func (a *Adapter) Init(ctx context.Context, deps *api.Dependencies) error {
	a.HealthCheck = base.WireHealth(a.Health)

	a.Log = deps.Logger
	c := cfg.Network(deps.Config)
	a.addr = c.Addr
	return nil
}

// Start implements api.Plugin.
func (a *Adapter) Start(ctx context.Context) error {
	if a.addr == "" {
		return errs.InvalidArgument("tcp adapter requires config.addr (e.g. :9000)")
	}
	return nil
}

// Stop implements api.Plugin.
func (a *Adapter) Stop(ctx context.Context) error { return a.Close(ctx) }

// Name implements network.Network.
func (a *Adapter) Name() string { return "tcp" }

// Open implements network.Network.
func (a *Adapter) Open(ctx context.Context, c network.Config) error {
	a.addr = c.Addr
	return nil
}

// Close implements network.Network.
func (a *Adapter) Close(ctx context.Context) error {
	a.mu.Lock()
	if a.cancel != nil {
		a.cancel()
	}
	if a.ln != nil {
		_ = a.ln.Close()
		a.ln = nil
	}
	for conn := range a.conns {
		_ = conn.Close()
	}
	a.mu.Unlock()
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
	return network.Health{OK: true, Message: "tcp healthy"}
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
	a.mu.Lock()
	if ctx.Err() != nil {
		a.mu.Unlock()
		return nil
	}
	ln, err := net.Listen("tcp", a.addr)
	if err != nil {
		a.mu.Unlock()
		return errs.Wrap(errs.CodePlugin, err, "tcp listen "+a.addr)
	}
	a.ln, a.cancel = ln, cancel
	a.mu.Unlock()
	stop := context.AfterFunc(ctx, func() {
		_ = ln.Close()
		a.mu.Lock()
		for conn, owner := range a.conns {
			if owner == ctx {
				_ = conn.Close()
			}
		}
		a.mu.Unlock()
	})
	defer stop()
	a.Log.Info("tcp serving", "addr", a.addr)
	for {
		conn, err := ln.Accept()
		if err != nil {
			if isClosed(err) || ctx.Err() != nil {
				return nil
			}
			return errs.Wrap(errs.CodePlugin, err, "tcp accept")
		}
		a.mu.Lock()
		if a.ln != ln || ctx.Err() != nil {
			a.mu.Unlock()
			_ = conn.Close()
			return nil
		}
		a.conns[conn] = ctx
		a.wg.Add(1)
		a.mu.Unlock()
		go func() {
			defer a.wg.Done()
			defer func() { a.mu.Lock(); delete(a.conns, conn); a.mu.Unlock() }()
			a.handleConn(ctx, conn)
		}()
	}
}

func (a *Adapter) handleConn(ctx context.Context, conn net.Conn) {
	defer conn.Close()
	defer func() {
		if rec := recover(); rec != nil {
			a.Log.Error("tcp handler panic", "error", rec)
		}
	}()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Minute))
	r := bufio.NewReader(conn)
	for {
		req, err := readFrame(r)
		if err != nil {
			if err != io.EOF {
				a.Log.Debug("tcp frame error", "peer", conn.RemoteAddr().String(), "error", err)
			}
			return
		}
		req.Peer = conn.RemoteAddr().String()
		handler, params, ok := a.router.Match(network.MethodCall, req.Path)
		if !ok {
			handler, params, ok = a.router.Match(req.Method, req.Path)
		}
		if !ok {
			_ = writeFrame(conn, &network.Response{Status: 404, Body: []byte(`{"error":"route not found"}`)})
			continue
		}
		if params != nil {
			if req.Header == nil {
				req.Header = map[string]string{}
			}
			b, _ := json.Marshal(params)
			req.Header["x-route-params"] = string(b)
		}
		resp, err := handler(ctx, req)
		if err != nil {
			resp = &network.Response{Status: 500, Body: []byte(mustJSON(map[string]any{"error": err.Error(), "code": errs.CodeOf(err)}))}
		}
		if err := writeFrame(conn, resp); err != nil {
			return
		}
	}
}

// Call implements network.Network.
func (a *Adapter) Call(ctx context.Context, addr string, req *network.Request) (*network.Response, error) {
	conn, err := (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "tcp dial "+addr)
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	if err := writeFrame(conn, req); err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "tcp write")
	}
	r := bufio.NewReader(conn)
	var length [4]byte
	if _, err := io.ReadFull(r, length[:]); err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "tcp read length")
	}
	n := binary.BigEndian.Uint32(length[:])
	if n > 1<<20 {
		return nil, errs.New(errs.CodeInvalidArgument, "tcp frame too large")
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "tcp read body")
	}
	resp := &network.Response{}
	if err := json.Unmarshal(buf, resp); err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "decode response")
	}
	return resp, nil
}

func readFrame(r *bufio.Reader) (*network.Request, error) {
	var length [4]byte
	if _, err := io.ReadFull(r, length[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(length[:])
	if n > 1<<20 { // 1 MiB cap
		return nil, errs.New(errs.CodeInvalidArgument, "tcp frame too large")
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	req := &network.Request{}
	if err := json.Unmarshal(buf, req); err != nil {
		return nil, errs.Wrap(errs.CodeInvalidArgument, err, "decode tcp frame")
	}
	return req, nil
}

func writeFrame(w io.Writer, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	var length [4]byte
	binary.BigEndian.PutUint32(length[:], uint32(len(b)))
	if _, err := w.Write(length[:]); err != nil {
		return err
	}
	_, err = w.Write(b)
	return err
}

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

func isClosed(err error) bool {
	return err != nil && (err.Error() == "use of closed network connection")
}
