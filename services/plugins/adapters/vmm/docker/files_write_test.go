package docker

import (
	"archive/tar"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/tradera/tradera/pkg/logger"
	vmm "github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// stoppedEngine is a Docker engine with one stopped computer whose
// /workspace is a volume; it records what was asked of it.
type stoppedEngine struct {
	mu       sync.Mutex
	tarNames []string
	tarData  map[string]string
	helper   []string // the helper's command line
	exit     int
	removed  bool
}

func (e *stoppedEngine) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	e.mu.Lock()
	defer e.mu.Unlock()
	switch {
	case r.Method == http.MethodPut && r.URL.Path == "/containers/c/archive":
		if r.URL.Query().Get("path") != "/workspace" {
			http.Error(w, "bad path", 400)
			return
		}
		tr := tar.NewReader(r.Body)
		for {
			h, err := tr.Next()
			if err == io.EOF {
				break
			}
			if err != nil {
				http.Error(w, err.Error(), 400)
				return
			}
			e.tarNames = append(e.tarNames, h.Name)
			b, _ := io.ReadAll(tr)
			e.tarData[h.Name] = string(b)
		}
	case r.URL.Path == "/containers/c/json":
		_, _ = w.Write([]byte(`{"Config":{"Image":"tradera/sandbox:1"},"Mounts":[{"Type":"volume","Name":"tradera-workspace-b1","Destination":"/workspace"}]}`))
	case r.URL.Path == "/containers/create":
		var body struct {
			Image      string   `json:"Image"`
			Cmd        []string `json:"Cmd"`
			HostConfig struct {
				Mounts []struct {
					Source string `json:"Source"`
				} `json:"Mounts"`
				NetworkMode string `json:"NetworkMode"`
			} `json:"HostConfig"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Image != "tradera/sandbox:1" || len(body.HostConfig.Mounts) != 1 || body.HostConfig.Mounts[0].Source != "tradera-workspace-b1" || body.HostConfig.NetworkMode != "none" {
			http.Error(w, "unexpected helper", 400)
			return
		}
		e.helper = body.Cmd
		_, _ = w.Write([]byte(`{"Id":"h"}`))
	case r.URL.Path == "/containers/h/start":
		w.WriteHeader(204)
	case r.URL.Path == "/containers/h/wait":
		_, _ = w.Write([]byte(`{"StatusCode":` + string(rune('0'+e.exit)) + `}`))
	case r.Method == http.MethodDelete && r.URL.Path == "/containers/h":
		e.removed = true
		w.WriteHeader(204)
	default:
		http.Error(w, "unexpected "+r.Method+" "+r.URL.Path, 404)
	}
}

func stopped(t *testing.T) (*Adapter, *stoppedEngine) {
	e := &stoppedEngine{tarData: map[string]string{}}
	srv := httptest.NewServer(e)
	t.Cleanup(srv.Close)
	a := New(logger.Global())
	a.baseURL = srv.URL
	a.client = srv.Client()
	a.vms["vm"] = "c"
	return a, e
}

func TestStoppedComputerFilesAreWrittenWithTheirFolders(t *testing.T) {
	a, e := stopped(t)
	ctx := context.Background()
	if err := a.WriteWorkspace(ctx, "vm", "src/app/main.go", []byte("package main")); err != nil {
		t.Fatal(err)
	}
	if strings.Join(e.tarNames, ",") != "src/,src/app/,src/app/main.go" || e.tarData["src/app/main.go"] != "package main" {
		t.Fatalf("archive = %v %v", e.tarNames, e.tarData)
	}
	e.tarNames = nil
	if err := a.MakeWorkspaceDir(ctx, "vm", "docs/notes"); err != nil {
		t.Fatal(err)
	}
	if strings.Join(e.tarNames, ",") != "docs/,docs/notes/" {
		t.Fatalf("folder archive = %v", e.tarNames)
	}
	if err := a.WriteWorkspace(ctx, "vm", "../etc/passwd", nil); err == nil {
		t.Fatal("wrote outside the workspace")
	}
}

func TestStoppedComputerFilesAreDeletedAndMovedByAHelper(t *testing.T) {
	a, e := stopped(t)
	ctx := context.Background()
	if err := a.DeleteWorkspace(ctx, "vm", "build"); err != nil {
		t.Fatal(err)
	}
	if len(e.helper) != 3 || e.helper[2] != "/workspace/build" || !strings.Contains(e.helper[0], "rm -rf") || !e.removed {
		t.Fatalf("delete helper = %v removed=%v", e.helper, e.removed)
	}
	if err := a.MoveWorkspace(ctx, "vm", "a.txt", "docs/b.txt"); err != nil {
		t.Fatal(err)
	}
	if e.helper[2] != "/workspace/a.txt" || e.helper[3] != "/workspace/docs/b.txt" {
		t.Fatalf("move helper = %v", e.helper)
	}
	e.exit = 3
	if err := a.MoveWorkspace(ctx, "vm", "a.txt", "b.txt"); !errors.Is(err, vmm.ErrExists) {
		t.Fatalf("move onto an existing file = %v", err)
	}
	if err := a.DeleteWorkspace(ctx, "vm", ""); err == nil {
		t.Fatal("deleted the workspace root")
	}
}
