package docker

import (
	"archive/tar"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
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
	listing  string
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
		_, _ = w.Write([]byte(`{"Config":{"Image":"aseman/sandbox:1"},"Mounts":[{"Type":"volume","Name":"aseman-workspace-b1","Destination":"/workspace"}]}`))
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
		if body.Image != "aseman/sandbox:1" || len(body.HostConfig.Mounts) != 1 || body.HostConfig.Mounts[0].Source != "aseman-workspace-b1" || body.HostConfig.NetworkMode != "none" {
			http.Error(w, "unexpected helper", 400)
			return
		}
		e.helper = body.Cmd
		_, _ = w.Write([]byte(`{"Id":"h"}`))
	case r.URL.Path == "/containers/h/start":
		w.WriteHeader(204)
	case r.URL.Path == "/containers/h/logs":
		// One stdout frame of Docker's multiplexed stream.
		out := []byte(e.listing)
		_, _ = w.Write(append([]byte{1, 0, 0, 0, byte(len(out) >> 24), byte(len(out) >> 16), byte(len(out) >> 8), byte(len(out))}, out...))
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

func TestAStoppedComputersFolderIsListedWithoutReadingItsContents(t *testing.T) {
	a, e := stopped(t)
	e.listing = "d|4096|node_modules\x00f|12|README.md\x00l|0|link\x00f|3|a b.txt\x00"
	entries, err := a.ListWorkspace(context.Background(), "vm", "")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 3 || entries[0].Name != "README.md" || entries[0].Size != 12 || entries[1].Name != "a b.txt" ||
		entries[2].Name != "node_modules" || entries[2].Type != "dir" {
		t.Fatalf("entries = %+v", entries)
	}
	if e.helper[2] != "/workspace" || !strings.Contains(e.helper[0], "-maxdepth 1") {
		t.Fatalf("listing helper = %v", e.helper)
	}
	e.exit = 3
	if _, err := a.ListWorkspace(context.Background(), "vm", "gone"); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("missing folder = %v", err)
	}
}

func TestReadingAFolderIsNotReadingAFileInIt(t *testing.T) {
	engine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// A folder: Docker says so in the stat header, before any contents.
		w.Header().Set("X-Docker-Container-Path-Stat", base64.StdEncoding.EncodeToString([]byte(`{"name":"src","mode":2147484141}`)))
		w.WriteHeader(200)
	}))
	defer engine.Close()
	a := New(logger.Global())
	a.baseURL, a.client = engine.URL, engine.Client()
	a.vms["vm"] = "c"
	if _, err := a.ReadWorkspace(context.Background(), "vm", "src"); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("read a folder = %v", err)
	}
}

func TestARunningComputersFolderIsListedByItself(t *testing.T) {
	var command []string
	engine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/containers/c/json":
			_, _ = w.Write([]byte(`{"State":{"Running":true}}`))
		case "/containers/c/exec":
			var body struct {
				Cmd []string `json:"Cmd"`
			}
			_ = json.NewDecoder(r.Body).Decode(&body)
			command = body.Cmd
			_, _ = w.Write([]byte(`{"Id":"x"}`))
		case "/exec/x/start":
			out := []byte("d|0|src\x00f|5|go.mod\x00")
			_, _ = w.Write(append([]byte{1, 0, 0, 0, 0, 0, 0, byte(len(out))}, out...))
		case "/exec/x/json":
			_, _ = w.Write([]byte(`{"ExitCode":0,"Running":false}`))
		default:
			http.Error(w, "unexpected "+r.URL.Path, 404)
		}
	}))
	defer engine.Close()
	a := New(logger.Global())
	a.baseURL, a.client = engine.URL, engine.Client()
	a.vms["vm"] = "c"
	entries, err := a.ListWorkspace(context.Background(), "vm", "app's")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 || entries[0].Name != "go.mod" || entries[1].Type != "dir" {
		t.Fatalf("entries = %+v", entries)
	}
	if !strings.Contains(strings.Join(command, " "), `cd '/workspace/app'\''s'`) {
		t.Fatalf("command = %v", command)
	}
}
