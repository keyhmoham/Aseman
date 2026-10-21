package spaces

import (
	"context"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
)

func addAccount(t *testing.T, s *Service, ctx context.Context, id, handle, role string, status account.Status) identity.ID {
	t.Helper()
	accID := mustID(t, id)
	now := time.Now().UTC()
	if err := s.R.CreateID(ctx, "accounts", accID, &account.Account{Entity: entity.Entity{ID: accID, CreatedAt: now, UpdatedAt: now},
		Kind: account.KindUser, Handle: handle, Role: role, Status: status}); err != nil {
		t.Fatal(err)
	}
	return accID
}

// Every active platform administrator becomes a project administrator of the
// admins space; other accounts are left out and the owner stays owner.
func TestSyncAdminsAddsEveryPlatformAdministrator(t *testing.T) {
	s, ctx := profileHarness(t)
	owner := addAccount(t, s, ctx, "00000000000000010000000000000001", "owner", "admin", account.StatusActive)
	admin := addAccount(t, s, ctx, "00000000000000010000000000000002", "second", "admin", account.StatusActive)
	disabled := addAccount(t, s, ctx, "00000000000000010000000000000003", "gone", "admin", account.StatusDisabled)
	user := addAccount(t, s, ctx, "00000000000000010000000000000004", "plain", "user", account.StatusActive)
	member := addAccount(t, s, ctx, "00000000000000010000000000000005", "member", "user", account.StatusActive)
	sp, err := s.CreateSpace(ctx, owner, "Admins", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.ensureAdminMember(ctx, sp.ID, member); err != nil {
		t.Fatal(err)
	}
	// A member who is promoted later is raised to project administrator.
	m, _ := s.SpaceMembership(ctx, sp.ID, member)
	m.Role = membership.RoleMember
	if err := s.R.Update(ctx, "memberships", m.ID, m); err != nil {
		t.Fatal(err)
	}
	var promoted account.Account
	_ = s.R.Get(ctx, "accounts", member, &promoted)
	promoted.Role = "admin"
	if err := s.R.Update(ctx, "accounts", member, &promoted); err != nil {
		t.Fatal(err)
	}

	added, err := s.syncAdmins(ctx, sp.ID)
	if err != nil {
		t.Fatal(err)
	}
	if added != 2 {
		t.Fatalf("added = %d; want 2 (the second admin and the promoted member)", added)
	}
	for id, want := range map[identity.ID]membership.Role{owner: membership.RoleOwner, admin: membership.RoleAdmin, member: membership.RoleAdmin} {
		m, err := s.SpaceMembership(ctx, sp.ID, id)
		if err != nil || m.Role != want {
			t.Fatalf("%s membership = %+v, %v; want %s", id, m, err, want)
		}
	}
	for _, id := range []identity.ID{disabled, user} {
		if _, err := s.SpaceMembership(ctx, sp.ID, id); err == nil {
			t.Fatalf("%s was added though not an active administrator", id)
		}
	}
	if added, err := s.syncAdmins(ctx, sp.ID); err != nil || added != 0 {
		t.Fatalf("second sync added %d, %v; want nothing", added, err)
	}
	if added, err := s.syncAdmins(ctx, mustID(t, "00000000000000010000000000000099")); err != nil || added != 0 {
		t.Fatalf("sync of a deleted project = %d, %v; want nothing", added, err)
	}
}
