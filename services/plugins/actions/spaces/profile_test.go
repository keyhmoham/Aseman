package spaces

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/permission"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/models/metadata"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

func profileHarness(t *testing.T) (*Service, context.Context) {
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
	s := NewService(k, r, logger.Global())
	return s, ctx
}

// Every project is private: a stored "public" flag opens nothing.
func TestAPublicFlagDoesNotOpenAProject(t *testing.T) {
	s, ctx := profileHarness(t)
	owner := mustID(t, "00000000000000010000000000000001")
	stranger := mustID(t, "00000000000000010000000000000002")
	sp, err := s.CreateSpace(ctx, owner, "Was Public", "desc")
	if err != nil {
		t.Fatal(err)
	}
	sp.Public = true
	if err := s.R.Update(ctx, "spaces", sp.ID, sp); err != nil {
		t.Fatal(err)
	}
	if err := s.Join(ctx, stranger, sp.ID); err == nil || errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("join without an invitation = %v; want permission denied", err)
	}
	if err := s.Can(ctx, sp.ID, identity.ID{}, stranger, permission.SpaceView); err == nil {
		t.Fatal("a stranger can view a project that has the public flag")
	}
}

func TestJoinPrivateSpaceRequiresInvite(t *testing.T) {
	s, ctx := profileHarness(t)
	owner := mustID(t, "00000000000000010000000000000001")
	member := mustID(t, "00000000000000010000000000000002")
	sp, err := s.CreateSpace(ctx, owner, "Private Workspace", "desc")
	if err != nil {
		t.Fatal(err)
	}
	err = s.Join(ctx, member, sp.ID)
	if err == nil || errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("expected permission error for private space, got %v", err)
	}
}

func TestSpaceProfileCounts(t *testing.T) {
	s, ctx := profileHarness(t)
	owner := mustID(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "Profile Space", "My workspace")
	if err != nil {
		t.Fatal(err)
	}
	// Create a second room (mirrors the room_create action).
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	room := &space.Room{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		SpaceID: sp.ID, Name: "research", MetadataID: id}
	if err := s.R.CreateID(ctx, "rooms", id, room); err != nil {
		t.Fatal(err)
	}
	profile, err := s.SpaceProfile(ctx, sp.ID)
	if err != nil {
		t.Fatal(err)
	}
	if profile["room_count"].(int) != 2 {
		t.Fatalf("room_count = %v, want 2", profile["room_count"])
	}
	if profile["member_count"].(int) != 1 {
		t.Fatalf("member_count = %v, want 1", profile["member_count"])
	}
	if profile["name"] != "Profile Space" {
		t.Fatalf("name = %v", profile["name"])
	}
}
func TestLeaveActionRemovesMembership(t *testing.T) {
	s, ctx := profileHarness(t)
	owner := mustID(t, "00000000000000010000000000000001")
	member := mustID(t, "00000000000000010000000000000002")
	sp, err := s.CreateSpace(ctx, owner, "Shared Workspace", "desc")
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	memID, _ := identity.New(1)
	if err := s.R.CreateID(ctx, "memberships", memID, &membership.Membership{Entity: entity.Entity{ID: memID, CreatedAt: now, UpdatedAt: now}, SpaceID: sp.ID, MemberID: member, Role: membership.RoleMember, JoinedAt: now}); err != nil {
		t.Fatal(err)
	}
	a := &leaveAction{s: s}
	body, _ := json.Marshal(map[string]any{"space": sp.ID.String()})
	if _, err := a.Handle(ctx, &api.ActionRequest{
		Caller: api.Caller{ID: member, Kind: "user"},
		Body:   body,
	}); err != nil {
		t.Fatalf("leave: %v", err)
	}
	if _, err := s.SpaceMembership(ctx, sp.ID, member); err == nil {
		t.Fatal("space membership still present after leave")
	}
}

func TestLeaveActionRejectsOwner(t *testing.T) {
	s, ctx := profileHarness(t)
	owner := mustID(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "My Workspace", "desc")
	if err != nil {
		t.Fatal(err)
	}
	a := &leaveAction{s: s}
	body, _ := json.Marshal(map[string]any{"space": sp.ID.String()})
	_, err = a.Handle(ctx, &api.ActionRequest{
		Caller: api.Caller{ID: owner, Kind: "user"},
		Body:   body,
	})
	if err == nil || errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("expected permission error for owner leave, got %v", err)
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

func TestAgentKnowsThePersonsLocalTimeWhenTheirTimezoneIsKnown(t *testing.T) {
	s, ctx := profileHarness(t)
	person := mustID(t, "00000000000000010000000000000001")
	if got := s.senderClock(ctx, person.String()); got != "" {
		t.Fatalf("an unknown timezone produced %q", got)
	}
	if err := s.R.CreateID(ctx, "metadatas", person, &metadata.Record{Owner: person.String(), Tree: metadata.Tree{}, PublicPaths: []string{"/profile"}, Version: 1, UpdatedAt: time.Now().UTC()}); err != nil {
		t.Fatal(err)
	}
	if err := s.M.Patch(ctx, person, jsonpatchSet("preferences/timezone", "Europe/London")); err != nil {
		t.Fatal(err)
	}
	got := s.senderClock(ctx, person.String())
	if !strings.Contains(got, "Europe/London") || !strings.Contains(got, "there now") {
		t.Fatalf("clock line = %q", got)
	}
	// A bad zone is ignored rather than passed to the model.
	if err := s.M.Patch(ctx, person, jsonpatchSet("preferences/timezone", "Mars/Base")); err != nil {
		t.Fatal(err)
	}
	if got := s.senderClock(ctx, person.String()); got != "" {
		t.Fatalf("a bad timezone produced %q", got)
	}
}
