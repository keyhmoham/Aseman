package docker

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/aseman/aseman/pkg/logger"
)

// fakeEngine answers the Docker Engine calls of a sleeping sandbox whose
// image tag was rebuilt since it was created.
type fakeEngine struct {
	mu       sync.Mutex
	calls    []string
	created  map[string]any
	running  bool
	newImage string
	failNew  bool
}

func (f *fakeEngine) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, r.Method+" "+r.URL.Path+"?"+r.URL.RawQuery)
	switch {
	case r.URL.Path == "/containers/old/json":
		_, _ = w.Write([]byte(`{"Name":"/aseman-sbx","Image":"sha256:old","State":{"Running":` + map[bool]string{true: "true", false: "false"}[f.running] + `},
			"Config":{"Image":"aseman/sandbox-computer:latest","Hostname":"old","Cmd":["sleep","infinity"],"Env":["A=1"],"Labels":{"aseman.vmid":"vm1","aseman.vm":"sbx"}},
			"HostConfig":{"NetworkMode":"aseman","Mounts":[{"Type":"volume","Source":"aseman-workspace-b1","Target":"/workspace"}]}}`))
	case r.URL.Path == "/images/aseman/sandbox-computer:latest/json":
		_, _ = w.Write([]byte(`{"Id":"` + f.newImage + `"}`))
	case r.URL.Path == "/containers/create":
		if f.failNew {
			w.WriteHeader(500)
			return
		}
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &f.created)
		_, _ = w.Write([]byte(`{"Id":"new"}`))
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

func (f *fakeEngine) did(prefix string) bool {
	for _, c := range f.calls {
		if strings.HasPrefix(c, prefix) {
			return true
		}
	}
	return false
}

func startWith(t *testing.T, f *fakeEngine) *Adapter {
	t.Helper()
	engine := httptest.NewServer(f)
	t.Cleanup(engine.Close)
	a := New(logger.Global())
	a.baseURL, a.client = engine.URL, engine.Client()
	a.vms["vm1"] = "old"
	if err := a.StartVM(context.Background(), "vm1"); err != nil {
		t.Fatal(err)
	}
	return a
}

func TestASleepingSandboxWakesOnItsImagesCurrentVersion(t *testing.T) {
	f := &fakeEngine{newImage: "sha256:new"}
	a := startWith(t, f)
	if a.vms["vm1"] != "new" || !f.did("POST /containers/new/start") {
		t.Fatalf("not recreated: %v %v", a.vms, f.calls)
	}
	if !f.did("POST /containers/old/rename?name=aseman-sbx-old") || !f.did("POST /containers/create?name=aseman-sbx") || !f.did("DELETE /containers/old") {
		t.Fatalf("calls: %v", f.calls)
	}
	host, _ := f.created["HostConfig"].(map[string]any)
	labels, _ := f.created["Labels"].(map[string]any)
	if f.created["Image"] != "aseman/sandbox-computer:latest" || labels["aseman.vmid"] != "vm1" || f.created["Hostname"] != nil ||
		!strings.Contains(mustJSON(host["Mounts"]), "aseman-workspace-b1") {
		t.Fatalf("the new container must keep the name, vm id and workspace volume: %v", f.created)
	}
}

func TestAnUpToDateOrRunningSandboxIsLeftAlone(t *testing.T) {
	for _, f := range []*fakeEngine{{newImage: "sha256:old"}, {newImage: "sha256:new", running: true}} {
		a := startWith(t, f)
		if a.vms["vm1"] != "old" || f.did("POST /containers/create") || f.did("DELETE") || !f.did("POST /containers/old/start") {
			t.Fatalf("changed: %v %v", a.vms, f.calls)
		}
	}
	t.Setenv("ASEMAN_DOCKER_REFRESH_IMAGES", "0")
	f := &fakeEngine{newImage: "sha256:new"}
	if a := startWith(t, f); a.vms["vm1"] != "old" || f.did("GET /containers/old/json") {
		t.Fatalf("refresh off: %v", f.calls)
	}
}

func TestAFailedRecreateKeepsTheOldMachine(t *testing.T) {
	f := &fakeEngine{newImage: "sha256:new", failNew: true}
	a := startWith(t, f)
	if a.vms["vm1"] != "old" || f.did("DELETE") || !f.did("POST /containers/old/start") {
		t.Fatalf("old machine not kept: %v %v", a.vms, f.calls)
	}
	last := ""
	for _, c := range f.calls {
		if strings.HasPrefix(c, "POST /containers/old/rename") {
			last = c
		}
	}
	if last != "POST /containers/old/rename?name=aseman-sbx" {
		t.Fatalf("not renamed back: %v", f.calls)
	}
}

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
