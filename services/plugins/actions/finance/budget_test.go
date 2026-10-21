package finance

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	financial "github.com/aseman/aseman/plugins/actions/finance/models"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func addProject(t *testing.T, s *Service, ctx context.Context, owner identity.ID) identity.ID {
	t.Helper()
	id, _ := identity.New(1)
	now := time.Now().UTC()
	if err := s.R.CreateID(ctx, "spaces", id, &space.Space{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, OwnerID: owner, Name: "launch"}); err != nil {
		t.Fatal(err)
	}
	memID, _ := identity.New(1)
	if err := s.R.CreateID(ctx, "memberships", memID, &membership.Membership{Entity: entity.Entity{ID: memID, CreatedAt: now, UpdatedAt: now}, SpaceID: id, MemberID: owner, Role: membership.RoleOwner, JoinedAt: now}); err != nil {
		t.Fatal(err)
	}
	return id
}

func inProject(ctx context.Context, project, room, actor identity.ID, agent string) context.Context {
	return vmm.WithExecution(ctx, vmm.Execution{ActorID: actor.String(), SpaceID: project.String(), RoomID: room.String(), AgentID: agent})
}

func TestBudgetStopsNewWorkAtTheCapButSettlesWorkAlreadyDone(t *testing.T) {
	s, ctx := financeHarness(t)
	alice := mustID(t, "00000000000000010000000000000001")
	bob := mustID(t, "00000000000000010000000000000002")
	project := addProject(t, s, ctx, alice)
	if err := s.SetBudget(ctx, alice, project, 100); err != nil {
		t.Fatal(err)
	}
	run := inProject(ctx, project, project, alice, "agent-1")
	charge := func(amount int64) error {
		return s.ChargeLines(run, alice, "turn", []wallet.ChargeLine{{Amount: amount, Payees: []identity.ID{bob}, Category: wallet.CategoryAgent}})
	}
	if err := charge(60); err != nil {
		t.Fatal(err)
	}
	// New work that cannot fit is refused at the gate.
	if err := s.EnsureFunds(run, alice, 50); err == nil || !strings.Contains(err.Error(), "budget exceeded") {
		t.Fatalf("EnsureFunds for work past the cap = %v", err)
	}
	if err := s.EnsureFunds(run, alice, 40); err != nil {
		t.Fatalf("work that fits exactly was refused: %v", err)
	}
	// Work already done is settled even when it ran a little past the cap: the
	// person pays for it and the project's spend shows it.
	if err := charge(70); err != nil {
		t.Fatalf("a settled charge was refused: %v", err)
	}
	if w, _ := s.GetWallet(ctx, alice); w.Balance != 1000-130 {
		t.Fatalf("balance %d; want 870", w.Balance)
	}
	if b, _ := s.Budget(ctx, project.String()); moneyNumber(b["cap"]) != 100 || moneyNumber(b["spent"]) != 130 {
		t.Fatalf("budget = %v; want cap 100, spent 130", b)
	}
	// Now over the cap, nothing new may start; other projects are unaffected.
	if err := s.EnsureFunds(run, alice, 1); err == nil || !strings.Contains(err.Error(), "budget exceeded") {
		t.Fatalf("EnsureFunds over the cap = %v", err)
	}
	other := addProject(t, s, ctx, alice)
	if err := s.EnsureFunds(inProject(ctx, other, other, alice, ""), alice, 1); err != nil {
		t.Fatalf("another project was blocked by this one's budget: %v", err)
	}
}

func TestBudgetBlankMeansNoLimitButSpendIsStillCounted(t *testing.T) {
	s, ctx := financeHarness(t)
	alice := mustID(t, "00000000000000010000000000000001")
	bob := mustID(t, "00000000000000010000000000000002")
	project := addProject(t, s, ctx, alice)
	run := inProject(ctx, project, project, alice, "agent-1")
	for i := 0; i < 3; i++ {
		if err := s.ChargeLines(run, alice, "turn", []wallet.ChargeLine{{Amount: 100, Payees: []identity.ID{bob}}}); err != nil {
			t.Fatal(err)
		}
	}
	if b, _ := s.Budget(ctx, project.String()); moneyNumber(b["cap"]) != 0 || moneyNumber(b["spent"]) != 300 {
		t.Fatalf("with no budget set: %v (want cap 0, spent 300)", b)
	}
	// A budget set afterwards is measured against everything spent so far, and
	// a cap of zero removes the limit again.
	if err := s.SetBudget(ctx, alice, project, 250); err != nil {
		t.Fatal(err)
	}
	if err := s.EnsureFunds(run, alice, 1); err == nil {
		t.Fatal("a budget below what is already spent must stop further runs")
	}
	if err := s.SetBudget(ctx, alice, project, 0); err != nil {
		t.Fatal(err)
	}
	if err := s.EnsureFunds(run, alice, 1); err != nil {
		t.Fatalf("clearing the budget did not lift the limit: %v", err)
	}
}

func TestChargesAreRecordedPerSpaceByWhatTheyPayFor(t *testing.T) {
	s, ctx := financeHarness(t)
	alice := mustID(t, "00000000000000010000000000000001")
	bob := mustID(t, "00000000000000010000000000000002")
	nodeop := mustID(t, "00000000000000010000000000000003")
	project := addProject(t, s, ctx, alice)
	run := inProject(ctx, project, project, alice, "agent-1")
	// An agent turn: agent time (paid to the node) and model tokens.
	if err := s.ChargeLines(run, alice, "agent turn", []wallet.ChargeLine{
		{Amount: 130, Payees: []identity.ID{nodeop}, PayeeTypes: []wallet.EntryType{wallet.EntryPayNode}, Category: wallet.CategoryAgent, Bot: "agent-1"},
		{Amount: 360, Payees: []identity.ID{bob}, Type: wallet.EntryPayLLM, Category: wallet.CategoryLLM, Bot: "agent-1"},
	}); err != nil {
		t.Fatal(err)
	}
	// Computer time and a tool call made by that agent.
	if err := s.ChargeLines(run, alice, "sandbox", []wallet.ChargeLine{{Amount: 10, Payees: []identity.ID{nodeop}, Category: wallet.CategoryCompute, Bot: "sbx-1"}}); err != nil {
		t.Fatal(err)
	}
	if err := s.ChargeLines(run, alice, "tool", []wallet.ChargeLine{{Amount: 5000, Payees: []identity.ID{bob, nodeop}, Category: wallet.CategoryTool, Bot: "tool-1"}}); err != nil {
		// alice has 1000: a tool call that costs more than her wallet is refused.
		if !strings.Contains(err.Error(), "insufficient") {
			t.Fatal(err)
		}
	}
	var rows []financial.Record
	if err := s.R.List(ctx, "financial_records", databaseFilter("settlement"), &rows); err != nil {
		t.Fatal(err)
	}
	got := map[string]int64{}
	bots := map[string]bool{}
	for _, r := range rows {
		if r.Data["space_id"] != project.String() {
			t.Fatalf("a charge was recorded against the wrong space: %v", r.Data)
		}
		for _, k := range []string{"agent_minor", "llm_minor", "compute_minor", "tool_minor"} {
			got[k] += moneyNumber(r.Data[k])
		}
		bots[r.Data["bot_id"].(string)] = true
	}
	if got["agent_minor"] != 130 || got["llm_minor"] != 360 || got["compute_minor"] != 10 {
		t.Fatalf("settlement split = %v; want agent 130, llm 360, compute 10", got)
	}
	if !bots["agent-1"] || !bots["sbx-1"] {
		t.Fatalf("charges not attributed to the bot they were for: %v", bots)
	}
	// A charge made with no project scope is not a project's usage.
	before := len(rows)
	if err := s.ChargeLines(ctx, alice, "outside", []wallet.ChargeLine{{Amount: 1, Payees: []identity.ID{bob}}}); err != nil {
		t.Fatal(err)
	}
	var after []financial.Record
	_ = s.R.List(ctx, "financial_records", databaseFilter("settlement"), &after)
	if len(after) != before {
		t.Fatalf("an unscoped charge created a project settlement")
	}
}

func databaseFilter(kind string) database.Filter {
	return database.Filter{Equal: map[string]any{"kind": kind}}
}

// The node's owner using their own computer pays nobody, but the project's
// record still shows the computer time: usage is not only what moved money.
func TestOwnUsageIsRecordedWithoutMovingMoney(t *testing.T) {
	s, ctx := financeHarness(t)
	alice := mustID(t, "00000000000000010000000000000001")
	bob := mustID(t, "00000000000000010000000000000002")
	project := addProject(t, s, ctx, alice)
	run := inProject(ctx, project, project, alice, "agent-1")
	before, err := s.GetWallet(ctx, alice)
	if err != nil {
		t.Fatal(err)
	}
	// Computer time on her own node, and an agent turn another account is paid for.
	if err := s.ChargeLines(run, alice, "computer time", []wallet.ChargeLine{{Amount: 40, Payees: []identity.ID{alice}, PayeeTypes: []wallet.EntryType{wallet.EntryPayNode}, Category: wallet.CategoryCompute, Bot: "sbx-1"}}); err != nil {
		t.Fatal(err)
	}
	if err := s.ChargeLines(run, alice, "agent turn", []wallet.ChargeLine{
		{Amount: 30, Payees: []identity.ID{alice}, PayeeTypes: []wallet.EntryType{wallet.EntryPayNode}, Category: wallet.CategoryAgent, Bot: "agent-1"},
		{Amount: 60, Payees: []identity.ID{bob}, Type: wallet.EntryPayLLM, Category: wallet.CategoryLLM, Bot: "agent-1"},
	}); err != nil {
		t.Fatal(err)
	}
	after, _ := s.GetWallet(ctx, alice)
	if before.Balance-after.Balance != 60 {
		t.Fatalf("only the model tokens cost money: balance moved by %d", before.Balance-after.Balance)
	}
	var rows []financial.Record
	if err := s.R.List(ctx, "financial_records", databaseFilter("settlement"), &rows); err != nil {
		t.Fatal(err)
	}
	var money, ownCompute, ownAgent, llm int64
	for _, r := range rows {
		money += r.Amount
		ownCompute += moneyNumber(r.Data["own_compute_minor"])
		ownAgent += moneyNumber(r.Data["own_agent_minor"])
		llm += moneyNumber(r.Data["llm_minor"])
		if moneyNumber(r.Data["compute_minor"]) != 0 {
			t.Fatalf("own computer time was counted as money: %v", r.Data)
		}
	}
	if len(rows) != 2 || money != 60 || ownCompute != 40 || ownAgent != 30 || llm != 60 {
		t.Fatalf("records=%d money=%d own compute=%d own agent=%d llm=%d", len(rows), money, ownCompute, ownAgent, llm)
	}
}
