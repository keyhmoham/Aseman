package apihttp

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	network "github.com/aseman/aseman/plugins/adapters/network/ports"
)

// A game's engine (index.wasm, ~35 MB) and packs (tens of MB) pass through a
// preview whole, streamed, with their length; pages are still read and
// rewritten as before.
func TestPreviewStreamsLargeBinariesAndRewritesPages(t *testing.T) {
	id := identity.ID{Node: 1, Entity: 2}
	big := bytes.Repeat([]byte("GDPC0123456789ab"), 40<<20/16) // 40 MiB, past the 32 MiB buffer limit
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/game.pck":
			w.Header().Set("Content-Type", "application/octet-stream")
			w.Header().Set("Content-Length", strconv.Itoa(len(big)))
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			_, _ = w.Write(big)
		default:
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write([]byte(`<html><head></head><body><script src="/_next/app.js"></script></body></html>`))
		}
	}))
	defer upstream.Close()
	p := &proxy.Proxy{Entity: entity.Entity{ID: id}, TargetURL: upstream.URL}
	a := &API{Auth: &previewAuth{valid: true}, Spaces: &previewSpaces{p: p, member: true}}
	call := func(path string) *network.Response {
		params, _ := json.Marshal(map[string]string{"id": id.String(), "*": path})
		resp, err := a.proxyServe(context.Background(), &network.Request{Path: p.GatewayPath() + path,
			Header: map[string]string{"x-route-params": string(params), "Authorization": "Bearer test-session"}})
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		return resp
	}

	resp := call("game.pck")
	if resp.Stream == nil || resp.Body != nil {
		t.Fatalf("a binary is not streamed: %+v", resp.Header)
	}
	if resp.Header["Content-Length"] != strconv.Itoa(len(big)) || resp.Header["Content-Type"] != "application/octet-stream" ||
		resp.Header["Cache-Control"] != "public, max-age=31536000, immutable" {
		t.Fatalf("headers %+v", resp.Header)
	}
	var got bytes.Buffer
	if err := resp.Stream(context.Background(), &got); err != nil || !bytes.Equal(got.Bytes(), big) {
		t.Fatalf("streamed %d of %d bytes: %v", got.Len(), len(big), err)
	}

	page := call("index.html")
	if page.Stream != nil || !bytes.Contains(page.Body, []byte(p.GatewayPath()+"_next/app.js")) {
		t.Fatalf("a page is not rewritten: %s", page.Body)
	}
}
