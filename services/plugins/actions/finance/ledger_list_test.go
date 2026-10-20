package finance

import (
	"testing"
	"time"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
)

// The node's whole ledger is for its admins; a person sees their own
// activity through finance.account.
func TestLedgerListIsForAdminsOnly(t *testing.T) {
	s, ctx := financeHarness(t)
	s.K = kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"admin_handle": "nodeop"}})
	alice := mustID(t, "00000000000000010000000000000001")
	nodeop := mustID(t, "00000000000000010000000000000003")
	now := time.Now().UTC()
	for _, a := range []account.Account{
		{Entity: entity.Entity{ID: nodeop, CreatedAt: now, UpdatedAt: now}, Kind: account.KindUser, Handle: "nodeop", Role: "admin", Status: account.StatusActive},
		{Entity: entity.Entity{ID: alice, CreatedAt: now, UpdatedAt: now}, Kind: account.KindUser, Handle: "alice", Status: account.StatusActive},
	} {
		a := a
		if err := s.R.CreateID(ctx, "accounts", a.ID, &a); err != nil {
			t.Fatal(err)
		}
	}
	list := &ledgerListAction{s: s}
	if _, err := list.Handle(ctx, &api.ActionRequest{Caller: api.Caller{ID: alice, Kind: "user"}}); err == nil {
		t.Fatal("a person who is not an admin listed the node's ledger")
	}
	if _, err := list.Handle(ctx, &api.ActionRequest{}); err == nil {
		t.Fatal("an anonymous caller listed the node's ledger")
	}
	if _, err := list.Handle(ctx, &api.ActionRequest{Caller: api.Caller{ID: nodeop, Kind: "user"}}); err != nil {
		t.Fatalf("the admin could not list the ledger: %v", err)
	}
}
