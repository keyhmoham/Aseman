package usages

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	financial "github.com/aseman/aseman/plugins/actions/finance/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
)

// The computer is charged a minute at a time; the history shows each time it
// was on as one row, and the totals are unchanged.
func TestComputerChargesAreShownAsSessions(t *testing.T) {
	s, ctx := usageHarness(t)
	owner := mustID(t, "00000000000000010000000000000001")
	project, _ := identity.New(1)
	base := time.Now().UTC().Add(-2 * time.Hour)
	if err := s.R.CreateID(ctx, "spaces", project, &space.Space{Entity: entity.Entity{ID: project, CreatedAt: base, UpdatedAt: base}, OwnerID: owner, Name: "launch"}); err != nil {
		t.Fatal(err)
	}
	memID, _ := identity.New(1)
	if err := s.R.CreateID(ctx, "memberships", memID, &membership.Membership{Entity: entity.Entity{ID: memID, CreatedAt: base, UpdatedAt: base}, SpaceID: project, MemberID: owner, Role: membership.RoleOwner, JoinedAt: base}); err != nil {
		t.Fatal(err)
	}
	charge := func(at time.Duration, bot, desc string, amount, compute int64) {
		id, _ := identity.New(1)
		when := base.Add(at)
		if err := s.R.CreateID(ctx, "financial_records", id, &financial.Record{ID: id.String(), Owner: owner.String(), Kind: "settlement", Amount: amount, Status: "completed",
			Data:      map[string]any{"space_id": project.String(), "space_name": "launch", "bot_id": bot, "description": desc, "compute_minor": compute, "agent_minor": amount - compute},
			CreatedAt: when, UpdatedAt: when}); err != nil {
			t.Fatal(err)
		}
	}
	// One session of three charges, an agent turn in the middle of it, and a
	// second session an hour later.
	charge(0, "sbx-1", "computer time", 20000, 20000)
	charge(1*time.Minute, "sbx-1", "computer time", 20000, 20000)
	charge(90*time.Second, "agent-1", "agent turn", 500, 0)
	charge(2*time.Minute, "sbx-1", "computer time", 9000, 9000)
	charge(time.Hour, "sbx-1", "computer time", 7000, 7000)

	resp, err := s.projects(ctx, &api.ActionRequest{Caller: api.Caller{ID: owner, Kind: "user"}, Body: []byte(`{"space":"` + project.String() + `"}`)}, false)
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		Projects []struct{ Spent, Compute int64 }
		Events   []struct {
			BotName   string    `json:"bot_name"`
			Charged   int64     `json:"charged"`
			CreatedAt time.Time `json:"created_at"`
			StartedAt time.Time `json:"started_at"`
		}
	}
	if err := json.Unmarshal(resp.Body, &out); err != nil {
		t.Fatal(err)
	}
	if len(out.Events) != 3 {
		t.Fatalf("events = %+v; want two computer sessions and the agent turn", out.Events)
	}
	// Newest first; a session sits where its last charge does.
	late, early, turn := out.Events[0], out.Events[1], out.Events[2]
	if late.BotName != "Computer" || late.Charged != 7000 {
		t.Fatalf("second session = %+v", late)
	}
	if turn.Charged != 500 || turn.BotName == "Computer" {
		t.Fatalf("the agent turn was folded into the computer: %+v", turn)
	}
	if early.BotName != "Computer" || early.Charged != 49000 || early.CreatedAt.Sub(early.StartedAt) != 2*time.Minute {
		t.Fatalf("first session = %+v; want 49000 over two minutes", early)
	}
	if p := out.Projects[0]; p.Spent != 56500 || p.Compute != 56000 {
		t.Fatalf("totals changed: %+v", p)
	}
}
