package tools

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"testing"
	"time"

	"github.com/tradera/tradera/plugins/actions/tools/mechanisms/mcp"
)

// A backend installed in a space's computer that was asleep starts answering
// only some seconds after the call reached it: the call waits, then runs.
func TestInstalledBackendIsWaitedForWhileItStarts(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close() // nothing answers yet: the computer is still waking
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			ID     any    `json:"id"`
			Method string `json:"method"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		w.Header().Set("Content-Type", "application/json")
		result := map[string]any{}
		if req.Method == "tools/call" {
			result = map[string]any{"content": []any{map[string]any{"type": "text", "text": "done"}}}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": result})
	})}
	go func() {
		time.Sleep(1500 * time.Millisecond)
		up, err := net.Listen("tcp", addr)
		if err != nil {
			return
		}
		_ = srv.Serve(up)
	}()
	defer srv.Close()
	s := &Service{}
	ep := &endpoint{URL: "http://" + addr + "/mcp", Headers: map[string]string{}, Client: mcp.New(true), Starting: 20 * time.Second}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := s.rpc(ctx, ep, "tools/call", map[string]any{"name": "x"})
	if err != nil {
		t.Fatalf("the call was not resumed once the backend answered: %v", err)
	}
	if out["content"] == nil {
		t.Fatalf("result = %v", out)
	}
	// An external backend (no start time) fails at once instead.
	ep = &endpoint{URL: "http://127.0.0.1:1/mcp", Headers: map[string]string{}, Client: mcp.New(true)}
	started := time.Now()
	if _, err := s.rpc(ctx, ep, "tools/call", nil); err == nil || time.Since(started) > 3*time.Second {
		t.Fatalf("external backend: %v after %s", err, time.Since(started))
	}
}
