package usages

import (
	"context"
	"testing"
	"time"

	"encoding/json"
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	financial "github.com/tradera/tradera/plugins/actions/finance/models"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
	"github.com/tradera/tradera/plugins/actions/spaces/models/space"
)

func settle(t *testing.T, s *Service, ctx context.Context, owner, project identity.ID, bot string, amount, agent, llm, compute, tool int64) {
	t.Helper()
	id, _ := identity.New(1)
	now := time.Now().UTC()
	if err := s.R.CreateID(ctx, "financial_records", id, &financial.Record{ID: id.String(), Owner: owner.String(), Kind: "settlement", Amount: amount, Status: "completed",
		Data:      map[string]any{"space_id": project.String(), "space_name": "launch", "bot_id": bot, "description": "x", "agent_minor": agent, "llm_minor": llm, "compute_minor": compute, "tool_minor": tool},
		CreatedAt: now, UpdatedAt: now}); err != nil {
		t.Fatal(err)
	}
}

// A project's usage splits what it spent into agents (their time and tokens),
// the computer and tools, and never counts one as another.
func TestProjectUsageSplitsAgentsComputerAndTools(t *testing.T) {
	s, ctx := usageHarness(t)
	owner := mustID(t, "00000000000000010000000000000001")
	project, _ := identity.New(1)
	now := time.Now().UTC()
	if err := s.R.CreateID(ctx, "spaces", project, &space.Space{Entity: entity.Entity{ID: project, CreatedAt: now, UpdatedAt: now}, OwnerID: owner, Name: "launch"}); err != nil {
		t.Fatal(err)
	}
	memID, _ := identity.New(1)
	if err := s.R.CreateID(ctx, "memberships", memID, &membership.Membership{Entity: entity.Entity{ID: memID, CreatedAt: now, UpdatedAt: now}, SpaceID: project, MemberID: owner, Role: membership.RoleOwner, JoinedAt: now}); err != nil {
		t.Fatal(err)
	}
	// An agent turn (130 time + 360 tokens), 10 of computer, a 5,000 tool call.
	settle(t, s, ctx, owner, project, "agent-1", 490, 130, 360, 0, 0)
	settle(t, s, ctx, owner, project, "sbx-1", 10, 0, 0, 10, 0)
	settle(t, s, ctx, owner, project, "tool-1", 5000, 0, 0, 0, 5000)

	body := []byte(`{"space":"` + project.String() + `"}`)
	resp, err := s.projects(ctx, &api.ActionRequest{Caller: api.Caller{ID: owner, Kind: "user"}, Body: body}, false)
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		Projects []struct {
			Spent, Compute, Tools, Agents, LLM int64
			Buckets                            []struct {
				Key     string
				Kind    string
				Charged int64
			}
		}
		Totals struct{ Spent, Compute, Tools, Agents, LLM int64 }
	}
	if err := json.Unmarshal(resp.Body, &out); err != nil {
		t.Fatal(err)
	}
	if len(out.Projects) != 1 {
		t.Fatalf("projects = %d", len(out.Projects))
	}
	p := out.Projects[0]
	if p.Spent != 5500 || p.Compute != 10 || p.Tools != 5000 || p.Agents != 490 || p.LLM != 360 {
		t.Fatalf("project usage = %+v; want spent 5500, computer 10, tools 5000, agents 490 (llm 360)", p)
	}
	if out.Totals.Spent != 5500 || out.Totals.Tools != 5000 || out.Totals.Agents != 490 {
		t.Fatalf("totals = %+v", out.Totals)
	}
	rows := map[string]int64{}
	for _, b := range p.Buckets {
		rows[b.Key+"/"+b.Kind] = b.Charged
	}
	if rows["agent:agent-1/agent"] != 490 || rows["tool:tool-1/tool"] != 5000 || rows["compute/compute"] != 10 || len(rows) != 3 {
		t.Fatalf("buckets = %v; want one agent, one tool and one computer row and nothing else", rows)
	}
}

// An agent's answer in a person's chat has no room: its charge is their own
// "Chats", on their usage, filterable on its own, and never another person's.
func TestChatChargesAreTheirOwnerUsageAsChats(t *testing.T) {
	s, ctx := usageHarness(t)
	me := mustID(t, "00000000000000010000000000000001")
	other := mustID(t, "00000000000000010000000000000002")
	for _, owner := range []identity.ID{me, other} {
		id, _ := identity.New(1)
		now := time.Now().UTC()
		if err := s.R.CreateID(ctx, "financial_records", id, &financial.Record{ID: id.String(), Owner: owner.String(), Kind: "settlement", Amount: 40, Status: "completed",
			Data:      map[string]any{"space_id": "", "space_name": "Chats", "scope": "chat", "bot_id": "writer", "description": "chat answer Writer", "agent_minor": int64(10), "llm_minor": int64(30)},
			CreatedAt: now, UpdatedAt: now}); err != nil {
			t.Fatal(err)
		}
	}
	type view struct {
		Projects []struct {
			SpaceID string `json:"space_id"`
			Name    string
			Chat    bool
			Spent   int64
		}
		Events []struct{ Chat bool }
	}
	for _, body := range []string{`{}`, `{"space":"chat"}`} {
		resp, err := s.projects(ctx, &api.ActionRequest{Caller: api.Caller{ID: me, Kind: "user"}, Body: []byte(body)}, false)
		if err != nil {
			t.Fatal(body, err)
		}
		var out view
		if err := json.Unmarshal(resp.Body, &out); err != nil {
			t.Fatal(err)
		}
		if len(out.Projects) != 1 || out.Projects[0].Name != "Chats" || !out.Projects[0].Chat || out.Projects[0].Spent != 40 || len(out.Events) != 1 || !out.Events[0].Chat {
			t.Fatalf("%s: %+v", body, out)
		}
	}
}
