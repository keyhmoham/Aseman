package http

import (
	"context"
	"github.com/gorilla/websocket"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
)

func (a *Adapter) serveTunnel(w http.ResponseWriter, r *http.Request, t *network.Tunnel) {
	if t.Protocol != "websocket" {
		http.Error(w, "unsupported duplex protocol", 501)
		return
	}
	headers := http.Header{}
	for k, v := range t.Header {
		headers.Set(k, v)
	}
	dialer := websocket.Dialer{Subprotocols: websocket.Subprotocols(r)}
	up, _, err := dialer.DialContext(r.Context(), t.Target, headers)
	if err != nil {
		http.Error(w, "upstream desktop unavailable", 502)
		return
	}
	defer up.Close()
	upgrader := websocket.Upgrader{Subprotocols: []string{up.Subprotocol()}, CheckOrigin: originAllowed}
	down, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	defer down.Close()
	stop := context.AfterFunc(r.Context(), func() { up.Close(); down.Close() })
	defer stop()
	done := make(chan struct{}, 2)
	copy := func(dst, src *websocket.Conn) {
		defer func() { done <- struct{}{} }()
		for {
			typ, b, e := src.ReadMessage()
			if e != nil {
				return
			}
			if e = dst.WriteMessage(typ, b); e != nil {
				return
			}
		}
	}
	go copy(up, down)
	go copy(down, up)
	<-done
	up.Close()
	down.Close()
	<-done
}

// originAllowed decides which web pages may open a desktop/tunnel WebSocket.
// The gateway has already authenticated the caller (session token and
// membership) before this runs; the origin check is the extra guard against a
// foreign page driving a logged-in browser. It allows:
//
//   - no Origin (not a browser);
//   - the page served from the same host the request came to, or the host a
//     reverse proxy says it forwarded (X-Forwarded-Host); when the proxy
//     passed the host without its port, the same machine on any port;
//   - local development, where the app and the node are both on localhost or
//     127.0.0.1 but on different ports;
//   - the origins listed in ASEMAN_ALLOWED_ORIGINS (comma separated; a bare
//     host or a full URL) and the node's public URL (ASEMAN_NODE_URL).
func originAllowed(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	u, err := url.Parse(origin)
	if err != nil || u.Host == "" {
		return false
	}
	if strings.EqualFold(u.Host, r.Host) || strings.EqualFold(u.Host, r.Header.Get("X-Forwarded-Host")) {
		return true
	}
	// A reverse proxy that passes the host without its port (nginx's $host)
	// still names the machine the page came from.
	for _, host := range []string{r.Host, r.Header.Get("X-Forwarded-Host")} {
		if host != "" && !strings.Contains(strings.TrimPrefix(host, "["), ":") && strings.EqualFold(u.Hostname(), strings.Trim(host, "[]")) {
			return true
		}
	}
	if isLoopback(u.Hostname()) && isLoopback(hostOnly(r.Host)) {
		return true
	}
	for _, allowed := range append(strings.Split(os.Getenv("ASEMAN_ALLOWED_ORIGINS"), ","), os.Getenv("ASEMAN_NODE_URL")) {
		allowed = strings.TrimSpace(allowed)
		if allowed == "" {
			continue
		}
		if a, err := url.Parse(allowed); err == nil && a.Host != "" {
			if strings.EqualFold(a.Host, u.Host) {
				return true
			}
		} else if strings.EqualFold(allowed, u.Host) || strings.EqualFold(allowed, u.Hostname()) {
			return true
		}
	}
	return false
}

func hostOnly(hostport string) string {
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		return h
	}
	return strings.Trim(hostport, "[]")
}

func isLoopback(host string) bool {
	switch strings.ToLower(host) {
	case "localhost", "127.0.0.1", "::1":
		return true
	}
	return false
}
