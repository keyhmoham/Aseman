package docker

import (
	"context"
	"github.com/tradera/tradera/pkg/errs"
	vmm "github.com/tradera/tradera/plugins/adapters/vmm/ports"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/tradera/tradera/pkg/logger"
)

func TestDaemonShutdownPreservesVMUntilExplicitDeletion(t *testing.T) {
	var methods []string
	engine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		methods = append(methods, r.Method)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer engine.Close()
	a := New(logger.Global())
	a.baseURL = engine.URL
	a.client = engine.Client()
	a.vms["workspace"] = "retained-container"
	if err := a.Stop(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(methods) != 0 || a.vms["workspace"] != "retained-container" {
		t.Fatalf("daemon shutdown changed durable VM: %v %v", methods, a.vms)
	}
	if err := a.DeleteVM(context.Background(), "workspace"); err != nil {
		t.Fatal(err)
	}
	if len(methods) != 1 || methods[0] != http.MethodDelete || a.vms["workspace"] != "" {
		t.Fatalf("explicit deletion failed: %v %v", methods, a.vms)
	}
}

func TestSandboxCommandDoesNotInventSuccessWhenInspectionFails(t *testing.T) {
	engine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/containers/c/exec":
			w.Write([]byte(`{"Id":"e"}`))
		case "/exec/e/start":
			w.Write([]byte("partial diagnostics"))
		default:
			w.WriteHeader(500)
		}
	}))
	defer engine.Close()
	a := New(logger.Global())
	a.baseURL = engine.URL
	a.client = engine.Client()
	a.vms["vm"] = "c"
	output, err := a.Send(context.Background(), "vm", "true")
	if err == nil || !strings.Contains(output, "partial diagnostics") || strings.Contains(output, "exit=0") {
		t.Fatalf("%q %v", output, err)
	}
}
func TestSandboxOOMHasActionableCodeAndPreservesOutput(t *testing.T) {
	engine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/containers/c/exec"):
			w.Write([]byte(`{"Id":"e"}`))
		case strings.HasSuffix(r.URL.Path, "/exec/e/start"):
			w.Write([]byte("Killed"))
		case strings.HasSuffix(r.URL.Path, "/exec/e/json"):
			w.Write([]byte(`{"Running":false,"ExitCode":137}`))
		case strings.HasSuffix(r.URL.Path, "/containers/c/json"):
			w.Write([]byte(`{"State":{"OOMKilled":true}}`))
		default:
			t.Errorf("unexpected %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer engine.Close()
	a := New(logger.Global())
	a.baseURL = engine.URL
	a.client = engine.Client()
	a.vms["vm"] = "c"
	output, err := a.Send(context.Background(), "vm", "npm run build")
	if errs.CodeOf(err) != vmm.CodeSandboxMemoryLimit || !strings.Contains(output, "Killed") || !strings.Contains(output, "exit=137") {
		t.Fatalf("%q %v", output, err)
	}
}
func TestDockerStreamUsesExecutionDeadlineAndReturnsPartialBytes(t *testing.T) {
	engine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("before interruption"))
		w.(http.Flusher).Flush()
		select {
		case <-r.Context().Done():
		case <-time.After(time.Second):
		}
	}))
	defer engine.Close()
	a := New(logger.Global())
	a.baseURL = engine.URL
	a.client = engine.Client()
	a.client.Timeout = 5 * time.Millisecond
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	started := time.Now()
	out, err := a.execStream(ctx, "/start", nil)
	if err == nil || !strings.Contains(string(out), "before interruption") || time.Since(started) < 20*time.Millisecond {
		t.Fatalf("%q %v elapsed=%s", out, err, time.Since(started))
	}
}
