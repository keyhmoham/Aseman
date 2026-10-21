package http

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
)

// The desktop's socket through the app's nginx: the page is served on
// host:3000, and nginx passes the Host without its port (and the host with
// it as X-Forwarded-Host). The tunnel must open, not loop on a refusal.
func TestDesktopSocketThroughAPortDroppingProxy(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		_ = c.WriteMessage(websocket.BinaryMessage, []byte("RFB 003.008\n"))
	}))
	defer upstream.Close()
	a := &Adapter{}
	node := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a.serveTunnel(w, r, &network.Tunnel{Protocol: "websocket", Target: "ws" + strings.TrimPrefix(upstream.URL, "http")})
	}))
	defer node.Close()
	for _, h := range []http.Header{
		{"Origin": {"http://pixelar.games:3000"}, "Host": {"pixelar.games"}},
		{"Origin": {"http://pixelar.games:3000"}, "Host": {"tradera:8080"}, "X-Forwarded-Host": {"pixelar.games:3000"}},
	} {
		d := websocket.Dialer{}
		// The Host header is the request's own: set it as nginx would.
		host := h.Get("Host")
		h.Del("Host")
		u := "ws" + strings.TrimPrefix(node.URL, "http") + "/v1/proxy/x/websockify"
		c, resp, err := dialWithHost(d, u, host, h)
		if err != nil {
			status := 0
			if resp != nil {
				status = resp.StatusCode
			}
			t.Fatalf("headers %v host %s: %v (status %d)", h, host, err, status)
		}
		_, msg, err := c.ReadMessage()
		c.Close()
		if err != nil || !strings.HasPrefix(string(msg), "RFB ") {
			t.Fatalf("no greeting through the tunnel: %q, %v", msg, err)
		}
	}
}

// dialWithHost dials u but sends [host] as the Host header, as a reverse
// proxy in front of the node would.
func dialWithHost(d websocket.Dialer, u, host string, h http.Header) (*websocket.Conn, *http.Response, error) {
	h = h.Clone()
	h.Set("Host", host)
	return d.Dial(u, h)
}
