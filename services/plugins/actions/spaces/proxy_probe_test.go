package spaces

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/aseman/aseman/internal/plugins/identity"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
)

func TestProxyProbeHTTPIdentityAndCredentialBoundary(t *testing.T) {
	body := "<!doctype html><title>Actual site</title>"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer private-token" {
			t.Error("missing private tunnel authorization")
		}
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte(body))
	}))
	defer server.Close()
	record := &proxy.Proxy{TargetURL: server.URL, Token: "private-token", Path: "/v1/proxy/actual/"}
	result, err := probeProxy(context.Background(), record)
	if err != nil {
		t.Fatal(err)
	}
	var receipt struct {
		Status   int    `json:"status"`
		Passed   bool   `json:"passed"`
		Complete bool   `json:"complete"`
		SHA256   string `json:"sha256"`
		Bytes    int    `json:"bytes"`
	}
	if err := json.Unmarshal([]byte(result), &receipt); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(body))
	if receipt.Status != 200 || !receipt.Passed || !receipt.Complete || receipt.Bytes != len(body) || receipt.SHA256 != hex.EncodeToString(sum[:]) {
		t.Fatalf("incorrect HTTP evidence: %s", result)
	}
	if strings.Contains(result, record.Token) || strings.Contains(result, record.TargetURL) || strings.Contains(result, body) {
		t.Fatal("probe exposed credentials, private target or body")
	}
}

func TestProxyProbeDoesNotFollowRedirectsOrInventSuccess(t *testing.T) {
	forwarded := false
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { forwarded = true }))
	defer target.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, target.URL, http.StatusFound) }))
	defer server.Close()
	result, err := probeProxy(context.Background(), &proxy.Proxy{TargetURL: server.URL, Token: "private-token"})
	if err != nil || forwarded || !strings.Contains(result, `"status":302`) || !strings.Contains(result, `"passed":false`) {
		t.Fatalf("redirect evidence or credentials boundary failed: %s %v", result, err)
	}
}

func TestProxyProbeScopesBeforeMakingNetworkRequests(t *testing.T) {
	s, ctx := messageToolHarness(t)
	workspace := idFromHex(t, "00000000000000010000000000000001")
	other := idFromHex(t, "00000000000000010000000000000002")
	id := idFromHex(t, "00000000000000010000000000000003")
	record := &proxy.Proxy{SpaceID: workspace, TargetURL: "http://127.0.0.1:1/private", Token: "private-token"}
	record.ID = id
	if err := s.R.CreateID(ctx, "proxies", id, record); err != nil {
		t.Fatal(err)
	}
	_, err := s.proxyManageTool(ctx, other, "proxy_get", `{"id":"`+id.String()+`","probe":true}`)
	if err == nil || !strings.Contains(err.Error(), "another workspace") {
		t.Fatalf("missing workspace boundary: %v", err)
	}
	_, err = probeProxy(context.Background(), record)
	if err == nil || strings.Contains(err.Error(), record.TargetURL) || strings.Contains(err.Error(), record.Token) {
		t.Fatalf("network error leaked private target or credentials: %v", err)
	}
}

func TestPathPreservingPreviewReuseKeepsRoomOwnerAndPortBoundary(t *testing.T) {
	room := identity.ID{Node: 1, Entity: 2}
	owner := identity.ID{Node: 1, Entity: 3}
	record := proxy.Proxy{RoomID: room, OwnerID: owner, Port: 3000, Path: "/v1/proxy/test/", TargetURL: "http://sandbox:3000/v1/proxy/test/"}
	records := []proxy.Proxy{record}
	if got := reusablePathProxy(records, room, owner, 3000); got == nil || got.GatewayPath() != record.GatewayPath() {
		t.Fatal("matching stable preview not reused")
	}
	if reusablePathProxy(records, identity.ID{}, owner, 3000) != nil || reusablePathProxy(records, room, identity.ID{}, 3000) != nil || reusablePathProxy(records, room, owner, 8080) != nil {
		t.Fatal("unrelated preview was reused")
	}
	records[0].TargetURL = "http://sandbox:3000"
	if reusablePathProxy(records, room, owner, 3000) != nil {
		t.Fatal("legacy root preview reused for prefixed app")
	}
}
