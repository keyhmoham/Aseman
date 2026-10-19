// Package network defines the driven port for network protocol plugins (HTTP,
// custom TCP, WebSocket, ...). Actions are protocol-independent: adapters
// translate protocol requests into generic request/response calls.
package network

import (
	"context"
	"io"
	"net/url"
)

// Method is a protocol agnostic operation kind.
type Method string

const (
	MethodGet    Method = "GET"
	MethodPost   Method = "POST"
	MethodPut    Method = "PUT"
	MethodDelete Method = "DELETE"
	MethodPatch  Method = "PATCH"
	MethodCall   Method = "CALL" // RPC style (TCP/WS)
)

// Request is a protocol normalized request.
type Request struct {
	Method Method            `json:"method"`
	Route  string            `json:"route"`
	Path   string            `json:"path,omitempty"`
	Query  url.Values        `json:"query,omitempty"`
	Header map[string]string `json:"header,omitempty"`
	Body   []byte            `json:"body,omitempty"`
	Peer   string            `json:"peer,omitempty"` // remote address
	// Host is the host the caller addressed (the Host header, or the one a
	// trusted proxy forwarded), without a port. Adapters without a notion of
	// host leave it empty.
	Host    string        `json:"host,omitempty"`
	RawBody io.ReadCloser `json:"-"`
}

// Response is a protocol normalized response.
type Response struct {
	Tunnel *Tunnel           `json:"-"`
	Status int               `json:"status"`
	Header map[string]string `json:"header,omitempty"`
	Body   []byte            `json:"body,omitempty"`
	// Stream, when set, replaces Body: the adapter sends the headers and then
	// calls it with a writer whose every Write reaches the caller at once (a
	// server-sent event stream). Adapters that cannot stream (tcp, websocket)
	// collect what it writes into Body.
	Stream func(ctx context.Context, w io.Writer) error `json:"-"`
}

// Handler processes a normalized request.
type Handler func(ctx context.Context, req *Request) (*Response, error)

// Health of the network plugin.
type Health struct {
	OK      bool   `json:"ok"`
	Message string `json:"message,omitempty"`
}

// Config for a network plugin.
type Config struct {
	Addr    string            `json:"addr"`
	Path    string            `json:"path,omitempty"`
	TLS     *TLSConfig        `json:"tls,omitempty"`
	Options map[string]string `json:"options,omitempty"`
}

// TLSConfig enables TLS on the listener.
type TLSConfig struct {
	CertFile string `json:"cert_file,omitempty"`
	KeyFile  string `json:"key_file,omitempty"`
}

// Network is the driven port implemented by protocol adapters. It exposes both
// a server side (Serve/Handle) and a client side (Dial) so bots can also make
// outgoing calls through the same abstraction.
type Network interface {
	Name() string
	Open(ctx context.Context, cfg Config) error
	Close(ctx context.Context) error
	Health(ctx context.Context) Health

	// Handle registers a handler for a method+route pattern.
	Handle(method Method, route string, h Handler) error
	// Unhandle removes a previously registered handler.
	Unhandle(method Method, route string) error
	// Serve starts accepting connections (blocking until Close).
	Serve(ctx context.Context) error
	// Call performs an outbound request (client side).
	Call(ctx context.Context, addr string, req *Request) (*Response, error)
}
