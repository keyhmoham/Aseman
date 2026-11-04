package harness

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
)

// mismatchRuntime answers /healthz for anyone (like the real host) but gates
// /v1/questions on the secret it was started with.
type mismatchRuntime struct {
	secret string
	authOK atomic.Int64
}

func (m *mismatchRuntime) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/healthz":
		_, _ = w.Write([]byte(`{"ok":true}`))
	case "/v1/questions":
		if r.Header.Get("X-Aseman-Runtime") != m.secret {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
			return
		}
		m.authOK.Add(1)
		_ = json.NewEncoder(w).Encode(map[string]any{"questions": []any{}})
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func TestEnsureRuntimeRejectsSecretMismatchOnExternalRuntime(t *testing.T) {
	rt := &mismatchRuntime{secret: "runtime-side"}
	srv := httptest.NewServer(rt)
	t.Cleanup(srv.Close)

	a := New(logger.New(io.Discard, slog.LevelError))
	a.runtimeURL, a.secret, a.nodeURL = srv.URL, "node-side", "http://node:8080"

	err := a.ensureRuntime(context.Background())
	if err == nil || !strings.Contains(err.Error(), "runtime secret") {
		t.Fatalf("want a secret rejection, got %v", err)
	}
	if errs.CodeOf(err) != errs.CodeVMM {
		t.Fatalf("want VMM_ERROR, got %v", err)
	}
	if !a.healthyAt.IsZero() {
		t.Fatal("mismatched runtime must not be marked ready")
	}
}

func TestEnsureRuntimeAcceptsMatchingSecret(t *testing.T) {
	rt := &mismatchRuntime{secret: "shared"}
	srv := httptest.NewServer(rt)
	t.Cleanup(srv.Close)

	a := New(logger.New(io.Discard, slog.LevelError))
	a.runtimeURL, a.secret, a.nodeURL = srv.URL, "shared", "http://node:8080"

	if err := a.ensureRuntime(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rt.authOK.Load() == 0 {
		t.Fatal("ready check must probe an authenticated route")
	}
	// Cached readiness should not re-probe within the TTL.
	before := rt.authOK.Load()
	if err := a.ensureRuntime(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rt.authOK.Load() != before {
		t.Fatal("health TTL should skip a second probe")
	}
}

func TestLoadOrCreateRuntimeSecretPersists(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent-runtime-secret")

	first, err := loadOrCreateRuntimeSecret(path)
	if err != nil || first == "" {
		t.Fatalf("mint: %q %v", first, err)
	}
	second, err := loadOrCreateRuntimeSecret(path)
	if err != nil || second != first {
		t.Fatalf("reload: got %q want %q (%v)", second, first, err)
	}
	raw, err := os.ReadFile(path)
	if err != nil || strings.TrimSpace(string(raw)) != first {
		t.Fatalf("file: %q %v", raw, err)
	}
}
