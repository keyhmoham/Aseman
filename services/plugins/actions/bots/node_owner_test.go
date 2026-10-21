package bots

import (
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
)

// The node is owned by the account named after it, and when that account has
// taken another handle, by its longest-standing active admin. A node nobody
// owns cannot be paid for its computers.
func TestNodeOwnerSurvivesTheAdminChangingItsHandle(t *testing.T) {
	s, ctx, _, _ := entityHarness(t)
	s.K = kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"admin_handle": "node-a"}})
	add := func(handle, role string, status account.Status, age time.Duration) identity.ID {
		id, _ := identity.New(1)
		at := time.Now().UTC().Add(-age)
		if err := s.R.CreateID(ctx, "accounts", id, &account.Account{
			Entity: entity.Entity{ID: id, CreatedAt: at, UpdatedAt: at}, Handle: handle, Role: role, Kind: account.KindUser, Status: status,
		}); err != nil {
			t.Fatal(err)
		}
		return id
	}
	add("shayan", "", account.StatusActive, 3*time.Hour)
	if got := s.NodeOwnerID(ctx); !got.IsZero() {
		t.Fatalf("a node with no admin has no owner, got %s", got)
	}
	add("former", "admin", account.StatusDisabled, 5*time.Hour)
	renamed := add("asemanai", "admin", account.StatusActive, 4*time.Hour)
	add("newer", "admin", account.StatusActive, time.Hour)
	if got := s.NodeOwnerID(ctx); got != renamed {
		t.Fatalf("owner = %s, want the oldest active admin %s", got, renamed)
	}
	named := add("node-a", "", account.StatusActive, time.Minute)
	if got := s.NodeOwnerID(ctx); got != named {
		t.Fatalf("the account named after the node owns it: got %s", got)
	}
}
