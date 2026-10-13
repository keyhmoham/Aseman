package users

import (
	"context"
	"testing"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/support/metasvc"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/memory"
	dbmodel "github.com/tradera/tradera/plugins/testutil"
)

func followHarness(t *testing.T) (*Service, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := context.Background()
	for _, m := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global()})
	r := &repo.Repo{DB: db}
	s := &Service{K: k, R: r, M: &metasvc.Service{K: k, R: r}, L: logger.Global().Named("users")}
	a1 := &account.Account{Entity: entity.Entity{ID: mustID(t, "00000000000000010000000000000001")}, Handle: "alice", Kind: account.KindUser, Status: account.StatusActive}
	a2 := &account.Account{Entity: entity.Entity{ID: mustID(t, "00000000000000010000000000000002")}, Handle: "bob", Kind: account.KindUser, Status: account.StatusActive}
	if err := s.R.CreateID(ctx, "accounts", a1.ID, a1); err != nil {
		t.Fatal(err)
	}
	if err := s.R.CreateID(ctx, "accounts", a2.ID, a2); err != nil {
		t.Fatal(err)
	}
	return s, ctx
}

func TestFollowUnfollow(t *testing.T) {
	s, ctx := followHarness(t)
	alice := mustID(t, "00000000000000010000000000000001")
	bob := mustID(t, "00000000000000010000000000000002")

	if err := s.Follow(ctx, alice, bob); err != nil {
		t.Fatalf("follow: %v", err)
	}
	if ok, _ := s.IsFollowing(ctx, alice, bob); !ok {
		t.Fatal("expected alice to follow bob")
	}
	// Idempotent.
	if err := s.Follow(ctx, alice, bob); err != nil {
		t.Fatalf("follow (idempotent): %v", err)
	}
	followers, following, err := s.FollowCounts(ctx, bob)
	if err != nil {
		t.Fatal(err)
	}
	if followers != 1 || following != 0 {
		t.Fatalf("bob counts = %d/%d, want 1/0", followers, following)
	}
	if err := s.Follow(ctx, alice, alice); err == nil {
		t.Fatal("expected self-follow error")
	}
	if err := s.Unfollow(ctx, alice, bob); err != nil {
		t.Fatalf("unfollow: %v", err)
	}
	if ok, _ := s.IsFollowing(ctx, alice, bob); ok {
		t.Fatal("expected alice to stop following bob")
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
