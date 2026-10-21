package docker

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/aseman/aseman/pkg/logger"
)

func TestInventoryListsRunningSandboxesAndProjectVolumes(t *testing.T) {
	engine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/containers/json":
			if r.URL.Query().Get("all") != "false" || r.URL.Query().Get("filters") == "" {
				t.Fatalf("inventory query missing running/label filters: %s", r.URL.RawQuery)
			}
			_, _ = w.Write([]byte(`[{"Id":"container-1","Names":["/aseman-sbx-project"],"Created":1700000000,"Labels":{"aseman.vmid":"vm-1","aseman.vm":"sbx-project"}}]`))
		case "/containers/container-1/json":
			_, _ = w.Write([]byte(`{"State":{"StartedAt":"2026-10-13T06:30:00.123456789Z"}}`))
		case "/volumes":
			_, _ = w.Write([]byte(`{"Volumes":[{"Name":"aseman-workspace-bot-1","CreatedAt":"2026-10-12T01:02:03Z"},{"Name":"aseman-agent-state-bot-1","CreatedAt":"2026-10-12T01:02:03Z"},{"Name":"unrelated","CreatedAt":"2026-10-12T01:02:03Z"}]}`))
		default:
			t.Fatalf("unexpected Docker API path %s", r.URL.Path)
		}
	}))
	defer engine.Close()
	a := New(logger.Global())
	a.baseURL = engine.URL
	a.client = engine.Client()

	sandboxes, err := a.Sandboxes(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(sandboxes) != 1 || sandboxes[0].ID != "vm-1" || sandboxes[0].Machine != "sbx-project" {
		t.Fatalf("unexpected sandboxes: %#v", sandboxes)
	}
	if want := time.Date(2026, 10, 13, 6, 30, 0, 123456789, time.UTC); !sandboxes[0].StartedAt.Equal(want) {
		t.Fatalf("started_at=%s want %s", sandboxes[0].StartedAt, want)
	}

	volumes, err := a.Volumes(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(volumes) != 1 || volumes[0].Name != "aseman-workspace-bot-1" {
		t.Fatalf("unexpected volumes: %#v", volumes)
	}
}
