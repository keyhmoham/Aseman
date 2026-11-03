package spaces

import (
	"context"
	"encoding/json"
	"sync"
	"testing"

	"github.com/aseman/aseman/internal/plugins/api"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// fakeAgentMemory is the agent runtime's memory: notes per space and agent.
type fakeAgentMemory struct {
	mu    sync.Mutex
	notes map[string]string // space|agent → notes ("" agent: the space's)
	asked []string
}

func (f *fakeAgentMemory) EngineMemoryRead(_ context.Context, _ string, space, agent string) (*vmm.EngineMemoryView, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asked = append(f.asked, "read|"+space+"|"+agent)
	return &vmm.EngineMemoryView{Engine: "harness", SpaceNotes: f.notes[space+"|"], Agent: agent, Notes: f.notes[space+"|"+agent]}, nil
}

func (f *fakeAgentMemory) EngineMemoryWrite(_ context.Context, _ string, space, agent, content string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asked = append(f.asked, "write|"+space+"|"+agent)
	f.notes[space+"|"+agent] = content
	return nil
}

// People see and correct the agents' notes, kept in the agent runtime's
// memory, at the paths they had in the sandbox; agents' own reads still reach
// the sandbox.
func TestTheMemoryScreenReadsTheAgentsNotesFromTheirMemory(t *testing.T) {
	mem := &fakeAgentMemory{notes: map[string]string{}}
	s, ctx := fileToolHarness(t)
	s.agentMemoryFn = func() vmm.EngineMemory { return mem }
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "files", "")
	if err != nil {
		t.Fatal(err)
	}
	s.Bots = sandboxBots{mentionBots{BotPort: s.Bots}}
	agent := addAgent(t, s, ctx, sp.ID, "Data Wiz", "g-wiz")
	mem.notes[sp.ID.String()+"|"+agent.ID.String()] = "# Data Wiz notes\n- ann likes tabs\n"

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

	// The project's notes: saved to and read from the agents' memory.
	if out := call("person", `"operation":"write","path":"AGENTS.md","content":"# Project notes\n- deploys go through staging\n"`); out["ok"] != true {
		t.Fatalf("write: %v", out)
	}
	if got := mem.notes[sp.ID.String()+"|"]; got != "# Project notes\n- deploys go through staging\n" {
		t.Fatalf("stored: %q", got)
	}
	if out := call("person", `"operation":"read","path":"AGENTS.md"`); out["content"] != "# Project notes\n- deploys go through staging\n" {
		t.Fatalf("read: %v", out)
	}
	// Each agent's notes: listed by folder.
	out := call("person", `"operation":"list","path":".aseman/agents"`)
	items, _ := out["items"].([]any)
	names := map[string]bool{}
	for _, it := range items {
		names[it.(map[string]any)["name"].(string)] = true
	}
	if !names["data-wiz"] {
		t.Fatalf("list: %v", out)
	}
	if out := call("person", `"operation":"read","path":".aseman/agents/data-wiz/AGENTS.md"`); out["content"] != "# Data Wiz notes\n- ann likes tabs\n" {
		t.Fatalf("agent notes: %v", out)
	}
	// Another file is the sandbox's, and so is an agent's own read.
	before := len(mem.asked)
	call("person", `"operation":"read","path":"README.md"`)
	call("bot", `"operation":"read","path":"AGENTS.md"`)
	if len(mem.asked) != before {
		t.Fatalf("only people's notes requests reach the agents' memory: %v", mem.asked[before:])
	}
}
