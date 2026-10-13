package spaces

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/openviking"
)

// fakeViking answers OpenViking's read and write like the server, keeping
// files per account and recording who asked.
type fakeViking struct {
	mu    sync.Mutex
	files map[string]string // account|uri → text
	asked []string          // account|user|path
}

func (f *fakeViking) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.Header.Get("X-API-Key") != "root-key" {
		w.WriteHeader(401)
		_, _ = w.Write([]byte(`{"status":"error","error":{"code":"UNAUTHENTICATED","message":"no"}}`))
		return
	}
	account := r.Header.Get("X-OpenViking-Account")
	f.asked = append(f.asked, account+"|"+r.Header.Get("X-OpenViking-User")+"|"+r.URL.Path)
	switch r.URL.Path {
	case "/api/v1/content/read":
		text, ok := f.files[account+"|"+r.URL.Query().Get("uri")]
		if !ok {
			w.WriteHeader(404)
			_, _ = w.Write([]byte(`{"status":"error","error":{"code":"NOT_FOUND","message":"not found"}}`))
			return
		}
		out, _ := json.Marshal(map[string]any{"status": "ok", "result": text})
		_, _ = w.Write(out)
	case "/api/v1/content/write":
		var in struct{ URI, Content, Mode string }
		_ = json.NewDecoder(r.Body).Decode(&in)
		f.files[account+"|"+in.URI] = in.Content
		_, _ = w.Write([]byte(`{"status":"ok","result":{}}`))
	default:
		w.WriteHeader(404)
	}
}

// People see and correct the agents' notes, kept in OpenViking, at the paths
// they had in the sandbox; agents' own reads still reach the sandbox.
func TestTheMemoryScreenReadsTheAgentsNotesFromOpenViking(t *testing.T) {
	ov := &fakeViking{files: map[string]string{}}
	srv := httptest.NewServer(ov)
	t.Cleanup(srv.Close)
	t.Setenv(openviking.EnvURL, srv.URL)
	t.Setenv(openviking.EnvKey, "root-key")

	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "files", "")
	if err != nil {
		t.Fatal(err)
	}
	s.Bots = sandboxBots{mentionBots{BotPort: s.Bots}}
	agent := addAgent(t, s, ctx, sp.ID, "Data Wiz", "g-wiz")
	account := openviking.SpaceAccount(sp.ID.String())
	user := openviking.AgentUser(agent.ID.String())
	ov.files[account+"|"+openviking.AgentNotes(user)] = "# Data Wiz notes\n- ann likes tabs\n"

	call := func(callerKind, body string) map[string]any {
		t.Helper()
		caller := api.Caller{ID: owner}
		if callerKind == "bot" {
			caller = api.Caller{ID: agent.AccountID, Kind: "bot"}
		}
		resp, err := s.sandboxFilesAction(ctx, &api.ActionRequest{Caller: caller, Body: []byte(`{"space":"` + sp.ID.String() + `",` + body + `}`)})
		if err != nil {
			t.Fatalf("%s: %v", body, err)
		}
		var out map[string]any
		_ = json.Unmarshal(resp.Body, &out)
		return out
	}

	// The project's notes: saved to and read from OpenViking.
	if out := call("person", `"operation":"write","path":"AGENTS.md","content":"# Project notes\n- deploys go through staging\n"`); out["ok"] != true {
		t.Fatalf("write: %v", out)
	}
	if got := ov.files[account+"|"+openviking.SpaceNotes]; got != "# Project notes\n- deploys go through staging\n" {
		t.Fatalf("stored: %q", got)
	}
	if out := call("person", `"operation":"read","path":"AGENTS.md"`); out["content"] != "# Project notes\n- deploys go through staging\n" {
		t.Fatalf("read: %v", out)
	}
	// Each agent's notes: listed by folder, read as that agent.
	out := call("person", `"operation":"list","path":".tradera/agents"`)
	items, _ := out["items"].([]any)
	// Every agent of the space, the built-in lead included, by folder name.
	names := []string{}
	for _, it := range items {
		if it.(map[string]any)["type"] != "dir" {
			t.Fatalf("list: %v", out)
		}
		names = append(names, it.(map[string]any)["name"].(string))
	}
	if len(names) != 2 || names[0] != "data-wiz" || names[1] != "tradera" {
		t.Fatalf("list: %v", names)
	}
	if out := call("person", `"operation":"read","path":".tradera/agents/data-wiz/AGENTS.md"`); out["content"] != "# Data Wiz notes\n- ann likes tabs\n" {
		t.Fatalf("agent notes: %v", out)
	}
	if ov.asked[len(ov.asked)-1] != account+"|"+user+"|/api/v1/content/read" {
		t.Fatalf("an agent's notes are read as that agent: %v", ov.asked)
	}
	// Another file is the sandbox's, and so is an agent's own read.
	before := len(ov.asked)
	call("person", `"operation":"read","path":"README.md"`)
	call("bot", `"operation":"read","path":"AGENTS.md"`)
	if len(ov.asked) != before {
		t.Fatalf("only people's notes requests reach OpenViking: %v", ov.asked[before:])
	}
}
