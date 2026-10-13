package finance

import (
	"context"
	"testing"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/finance/models/wallet"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/memory"
	dbmodel "github.com/tradera/tradera/plugins/testutil"
)

func financeHarness(t *testing.T) (*Service, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := context.Background()
	for _, m := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global()})
	s := &Service{K: k, R: &repo.Repo{DB: db}, L: logger.Global().Named("finance")}
	for _, h := range []struct{ id, handle string }{
		{"00000000000000010000000000000001", "alice"},
		{"00000000000000010000000000000002", "bob"},
		{"00000000000000010000000000000003", "nodeop"},
	} {
		w := &wallet.Wallet{ID: mustID(t, h.id), OwnerID: mustID(t, h.id), Balance: 1000, Locked: 0}
		if err := s.R.CreateID(ctx, "wallets", w.ID, w); err != nil {
			t.Fatal(err)
		}
	}
	return s, ctx
}

func TestTransferDoesNotLoseMoneyOnMissingRecipient(t *testing.T) {
	s, ctx := financeHarness(t)
	alice := mustID(t, "00000000000000010000000000000001")
	ghost := mustID(t, "0000000000000001ffffffffffffffff")
	if _, err := s.Transfer(ctx, alice, ghost, 50); err == nil {
		t.Fatal("expected error for missing recipient")
	}
	w, err := s.GetWallet(ctx, alice)
	if err != nil {
		t.Fatal(err)
	}
	if w.Balance != 1000 {
		t.Fatalf("sender balance = %d, want 1000 (no money lost)", w.Balance)
	}
}

func TestTransferMovesCredits(t *testing.T) {
	s, ctx := financeHarness(t)
	alice := mustID(t, "00000000000000010000000000000001")
	bob := mustID(t, "00000000000000010000000000000002")
	if _, err := s.Transfer(ctx, alice, bob, 250); err != nil {
		t.Fatal(err)
	}
	a, _ := s.GetWallet(ctx, alice)
	b, _ := s.GetWallet(ctx, bob)
	if a.Balance != 750 || b.Balance != 1250 {
		t.Fatalf("after transfer: alice=%d bob=%d", a.Balance, b.Balance)
	}
}

func TestPayNodeMovesCredits(t *testing.T) {
	s, ctx := financeHarness(t)
	alice := mustID(t, "00000000000000010000000000000001")
	node := mustID(t, "00000000000000010000000000000003")
	if _, err := s.PayNode(ctx, alice, node, 100); err != nil {
		t.Fatal(err)
	}
	a, _ := s.GetWallet(ctx, alice)
	n, _ := s.GetWallet(ctx, node)
	if a.Balance != 900 || n.Balance != 1100 {
		t.Fatalf("after paynode: alice=%d node=%d", a.Balance, n.Balance)
	}
}

func TestBillChargesCustomerAndPaysBotOwnerAndNode(t *testing.T) {
	s, ctx := financeHarness(t)
	alice := mustID(t, "00000000000000010000000000000001") // customer
	bob := mustID(t, "00000000000000010000000000000002")   // bot owner
	node := mustID(t, "00000000000000010000000000000003")  // node owner

	// 60s at perMinute=2 → 2 credits, split between bot owner + node owner.
	if err := s.Bill(ctx, alice, bob, node, 2, 60, "ask"); err != nil {
		t.Fatal(err)
	}
	a, _ := s.GetWallet(ctx, alice)
	b, _ := s.GetWallet(ctx, bob)
	n, _ := s.GetWallet(ctx, node)
	if a.Balance != 998 {
		t.Fatalf("customer = %d, want 998 (charged 2)", a.Balance)
	}
	if b.Balance != 1001 || n.Balance != 1001 {
		t.Fatalf("bot owner=%d node=%d, want 1001/1001 (split)", b.Balance, n.Balance)
	}
}

func TestBillOwnBotPaysNodeOnly(t *testing.T) {
	s, ctx := financeHarness(t)
	alice := mustID(t, "00000000000000010000000000000001") // customer == bot owner
	node := mustID(t, "00000000000000010000000000000003")
	if err := s.Bill(ctx, alice, alice, node, 1, 60, "own bot"); err != nil {
		t.Fatal(err)
	}
	a, _ := s.GetWallet(ctx, alice)
	n, _ := s.GetWallet(ctx, node)
	if a.Balance != 999 {
		t.Fatalf("customer = %d, want 999", a.Balance)
	}
	if n.Balance != 1001 {
		t.Fatalf("node = %d, want 1001 (whole charge)", n.Balance)
	}
}

func TestBillInsufficientFunds(t *testing.T) {
	s, ctx := financeHarness(t)
	poor := mustID(t, "00000000000000010000000000000002")
	node := mustID(t, "00000000000000010000000000000003")
	// Drain bob's wallet.
	bob, _ := s.GetWallet(ctx, poor)
	if err := s.debit(ctx, bob, bob.Balance); err != nil {
		t.Fatal(err)
	}
	if err := s.Bill(ctx, poor, mustID(t, "00000000000000010000000000000001"), node, 1, 60, "ask"); err == nil {
		t.Fatal("expected insufficient funds error")
	}
	if errs.CodeOf(errs.New(errs.CodeFinance, "x")) != errs.CodeFinance {
		t.Fatal("finance code mismatch")
	}
}

func TestEnsureFundsGate(t *testing.T) {
	s, ctx := financeHarness(t)
	alice := mustID(t, "00000000000000010000000000000001")
	poor := mustID(t, "00000000000000010000000000000002")
	if err := s.EnsureFunds(ctx, alice, 50); err != nil {
		t.Fatalf("alice should pass the gate: %v", err)
	}
	bob, _ := s.GetWallet(ctx, poor)
	if err := s.debit(ctx, bob, bob.Balance); err != nil {
		t.Fatal(err)
	}
	if err := s.EnsureFunds(ctx, poor, 1); err == nil {
		t.Fatal("bob should fail the gate with no balance")
	}
	if err := s.EnsureFunds(ctx, alice, 0); err != nil {
		t.Fatalf("zero min cost should pass: %v", err)
	}
}

func mustID(t *testing.T, s string) identity.ID {
	t.Helper()
	id, err := identity.Parse(s)
	if err != nil {
		t.Fatal(err)
	}
	return id
}
func TestChargeLinesPaysLLMOwnerSeparately(t *testing.T) {
	s, ctx := financeHarness(t)
	alice := mustID(t, "00000000000000010000000000000001")
	bob := mustID(t, "00000000000000010000000000000002")
	nodeop := mustID(t, "00000000000000010000000000000003")
	err := s.ChargeLines(ctx, alice, "ask", []wallet.ChargeLine{
		{Amount: 10, Payees: []identity.ID{bob, nodeop},
			PayeeTypes: []wallet.EntryType{wallet.EntryPayBot, wallet.EntryPayNode}},
		{Amount: 7, Payees: []identity.ID{nodeop}, Type: wallet.EntryPayLLM},
	})
	if err != nil {
		t.Fatal(err)
	}
	balance := func(id identity.ID) int64 {
		w, err := s.GetWallet(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		return w.Balance
	}
	if balance(alice) != 1000-17 || balance(bob) != 1005 || balance(nodeop) != 1000+5+7 {
		t.Fatalf("balances alice=%d bob=%d nodeop=%d", balance(alice), balance(bob), balance(nodeop))
	}
	entries, _ := s.ListLedger(ctx, 50)
	var llmPaid int64
	for _, e := range entries {
		if e.Type == wallet.EntryPayLLM && e.ToID == nodeop {
			llmPaid += e.Amount
		}
	}
	if llmPaid != 7 {
		t.Fatalf("pay_llm ledger total = %d, want 7", llmPaid)
	}
}

func TestChargeLinesChecksTotalBalanceFirst(t *testing.T) {
	s, ctx := financeHarness(t)
	alice := mustID(t, "00000000000000010000000000000001")
	bob := mustID(t, "00000000000000010000000000000002")
	err := s.ChargeLines(ctx, alice, "big", []wallet.ChargeLine{
		{Amount: 600, Payees: []identity.ID{bob}},
		{Amount: 600, Payees: []identity.ID{bob}, Type: wallet.EntryPayLLM},
	})
	if err == nil {
		t.Fatal("expected insufficient balance")
	}
	if w, _ := s.GetWallet(ctx, alice); w.Balance != 1000 {
		t.Fatalf("no money may move on a failed charge, balance=%d", w.Balance)
	}
}
