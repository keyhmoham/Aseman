package finance

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	financial "github.com/aseman/aseman/plugins/actions/finance/models"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
)

func TestOverviewSplitsSpendByPartAndSeparatesCreatorsFromThePlatform(t *testing.T) {
	s, ctx := financeHarness(t)
	s.K = kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"admin_handle": "nodeop"}})
	alice := mustID(t, "00000000000000010000000000000001")
	bob := mustID(t, "00000000000000010000000000000002")
	nodeop := mustID(t, "00000000000000010000000000000003")
	now := time.Now().UTC()
	for _, a := range []account.Account{
		{Entity: entity.Entity{ID: nodeop, CreatedAt: now, UpdatedAt: now}, Kind: account.KindUser, Handle: "nodeop", Role: "admin", Status: account.StatusActive},
		{Entity: entity.Entity{ID: bob, CreatedAt: now, UpdatedAt: now}, Kind: account.KindUser, Handle: "bob", Status: account.StatusActive},
		{Entity: entity.Entity{ID: alice, CreatedAt: now, UpdatedAt: now}, Kind: account.KindUser, Handle: "alice", Status: account.StatusActive},
	} {
		a := a
		if err := s.R.CreateID(ctx, "accounts", a.ID, &a); err != nil {
			t.Fatal(err)
		}
	}
	project := addProject(t, s, ctx, alice)
	run := inProject(ctx, project, project, alice, "agent-1")
	// Agent time to the creator (bob), model tokens and computer to the platform.
	if err := s.ChargeLines(run, alice, "turn", []wallet.ChargeLine{
		{Amount: 100, Payees: []identity.ID{bob}, Category: wallet.CategoryAgent, Bot: "agent-1"},
		{Amount: 300, Payees: []identity.ID{nodeop}, Type: wallet.EntryPayLLM, Category: wallet.CategoryLLM, Bot: "agent-1"},
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.ChargeLines(run, alice, "sandbox", []wallet.ChargeLine{{Amount: 40, Payees: []identity.ID{nodeop}, PayeeTypes: []wallet.EntryType{wallet.EntryPayNode}, Category: wallet.CategoryCompute, Bot: "sbx-1"}}); err != nil {
		t.Fatal(err)
	}
	// A real pack and a test pack: only the real one is income.
	for i, sandbox := range []bool{false, true} {
		id, _ := identity.New(1)
		rec := financial.Record{ID: id.String(), Owner: alice.String(), Kind: "purchase", Amount: 2_000_000, Status: "completed", Data: map[string]any{"sandbox": sandbox}, CreatedAt: now, UpdatedAt: now}
		if err := s.R.DB.Create(ctx, "financial_records", rec.ID, &rec); err != nil {
			t.Fatalf("purchase %d: %v", i, err)
		}
	}

	resp, err := s.overview(ctx, &api.ActionRequest{Caller: api.Caller{ID: nodeop, Kind: "user"}})
	if err == nil && resp == nil {
		t.Fatal("empty response")
	}
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		Income  map[string]int64 `json:"income"`
		Charged map[string]int64 `json:"charged"`
		PaidOut map[string]int64 `json:"paid_out"`
		Kept    int64            `json:"kept"`
		Held    int64            `json:"held_by_users"`
	}
	if err := json.Unmarshal(resp.Body, &out); err != nil {
		t.Fatal(err)
	}
	if out.Income["credits_sold"] != 2_000_000 || out.Income["purchases"] != 1 {
		t.Fatalf("income = %v; the test pack must not count", out.Income)
	}
	if out.Charged["total"] != 440 || out.Charged["llm"] != 300 || out.Charged["compute"] != 40 || out.Charged["agent_time"] != 100 {
		t.Fatalf("charged = %v", out.Charged)
	}
	if out.PaidOut["creators"] != 100 || out.PaidOut["platform_llm"] != 300 || out.PaidOut["platform_compute"] != 40 {
		t.Fatalf("paid out = %v", out.PaidOut)
	}
	if out.Kept != 340 {
		t.Fatalf("kept = %d, want 340 (spend minus what creators were paid)", out.Kept)
	}
	// alice and bob hold what is left in their wallets; the platform's own wallet is not a liability.
	if out.Held <= 0 {
		t.Fatalf("held by users = %d", out.Held)
	}
}

func TestAdminAccountShowsBoughtGrantedAndSpentByPartAndProject(t *testing.T) {
	s, ctx := financeHarness(t)
	s.K = kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"admin_handle": "nodeop", "central": "true"}})
	alice := mustID(t, "00000000000000010000000000000001")
	nodeop := mustID(t, "00000000000000010000000000000003")
	now := time.Now().UTC()
	op := account.Account{Entity: entity.Entity{ID: nodeop, CreatedAt: now, UpdatedAt: now}, Kind: account.KindUser, Handle: "nodeop", Role: "admin", Status: account.StatusActive}
	if err := s.R.CreateID(ctx, "accounts", op.ID, &op); err != nil {
		t.Fatal(err)
	}
	project := addProject(t, s, ctx, alice)
	run := inProject(ctx, project, project, alice, "agent-1")
	if _, err := s.Mint(ctx, nodeop, alice, 500, "welcome gift"); err != nil {
		t.Fatal(err)
	}
	if err := s.ChargeLines(run, alice, "turn", []wallet.ChargeLine{
		{Amount: 300, Payees: []identity.ID{nodeop}, Type: wallet.EntryPayLLM, Category: wallet.CategoryLLM},
		{Amount: 40, Payees: []identity.ID{nodeop}, PayeeTypes: []wallet.EntryType{wallet.EntryPayNode}, Category: wallet.CategoryCompute},
	}); err != nil {
		t.Fatal(err)
	}
	id, _ := identity.New(1)
	rec := financial.Record{ID: id.String(), Owner: alice.String(), Kind: "purchase", Amount: 2_000_000, Status: "completed", Data: map[string]any{}, CreatedAt: now, UpdatedAt: now}
	if err := s.R.DB.Create(ctx, "financial_records", rec.ID, &rec); err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]any{"account": alice.String()})
	resp, err := s.adminAccount(ctx, &api.ActionRequest{Caller: api.Caller{ID: nodeop, Kind: "user"}, Body: body})
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		Bought, Granted, Spent int64
		SpentBy                map[string]int64 `json:"spent_by"`
		Projects               []map[string]any `json:"projects"`
	}
	if err := json.Unmarshal(resp.Body, &out); err != nil {
		t.Fatal(err)
	}
	if out.Bought != 2_000_000 || out.Granted != 500 || out.Spent != 340 || out.SpentBy["llm"] != 300 || out.SpentBy["compute"] != 40 || len(out.Projects) != 1 {
		t.Fatalf("admin account = %+v", out)
	}
}
