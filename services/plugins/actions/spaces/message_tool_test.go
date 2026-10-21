package spaces

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/bots"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

func messageToolHarness(t *testing.T) (*Service, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global()})
	s := NewService(k, &repo.Repo{DB: db}, logger.Global())
	s.Bots = bots.NewService(k, s.R, logger.Global())
	return s, ctx
}

func TestMessageToolPostsToRoom(t *testing.T) {
	s, ctx := messageToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "test space", "")
	if err != nil {
		t.Fatal(err)
	}
	dec, err := s.AsemanAccount(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.messageTool(ctx, sp.ID, `{"body":"hello from aseman"}`); err != nil {
		t.Fatal(err)
	}
	var msgs []message.Message
	if err := s.R.List(ctx, "messages", database.Filter{
		Equal: map[string]any{"space_id": sp.ID.String(), "sender_id": dec.String()},
	}, &msgs); err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 || msgs[0].Body != "hello from aseman" {
		t.Fatalf("expected one message from aseman, got %d (bodies %v)", len(msgs), msgs)
	}
}

// TestMessageToolDefaultsToContextRoom guards the wrong-room bug: when an agent
// (or aseman) posts via message_send without naming a room, the message must
// land in the room the request is running in (carried in the context), NOT the
// space's general room.
func TestMessageToolDefaultsToContextRoom(t *testing.T) {
	s, ctx := messageToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "test space", "")
	if err != nil {
		t.Fatal(err)
	}
	// A second room the conversation could be happening in.
	room2 := idFromHex(t, "00000000000000010000000000000009")
	now := time.Now().UTC()
	if err := s.R.CreateID(ctx, "rooms", room2, &space.Room{
		Entity:  entity.Entity{ID: room2, CreatedAt: now, UpdatedAt: now},
		SpaceID: sp.ID, Name: "design", MetadataID: room2,
	}); err != nil {
		t.Fatal(err)
	}

	// No room in the args, but the request context carries the room.
	roomCtx := vmm.WithRoom(ctx, room2.String())
	if _, err := s.messageTool(roomCtx, sp.ID, `{"body":"status update"}`); err != nil {
		t.Fatal(err)
	}
	var msgs []message.Message
	if err := s.R.List(ctx, "messages", database.Filter{
		Equal: map[string]any{"space_id": sp.ID.String(), "room_id": room2.String()},
	}, &msgs); err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 || msgs[0].Body != "status update" {
		t.Fatalf("expected the message in the context room, got %d messages: %+v", len(msgs), msgs)
	}
	// And nothing leaked into the general room.
	var general []message.Message
	if err := s.R.List(ctx, "messages", database.Filter{
		Equal: map[string]any{"space_id": sp.ID.String()},
	}, &general); err != nil {
		t.Fatal(err)
	}
	if len(general) != 1 {
		t.Fatalf("message leaked into the wrong room: %+v", general)
	}
}

func TestMessageToolParsesKeyValueInput(t *testing.T) {
	s, ctx := messageToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "test space", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.messageTool(ctx, sp.ID, `{"input":"body=status update from the orchestrator"}`); err != nil {
		t.Fatal(err)
	}
	var msgs []message.Message
	if err := s.R.List(ctx, "messages", database.Filter{
		Equal: map[string]any{"space_id": sp.ID.String()},
	}, &msgs); err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 || msgs[0].Body != "status update from the orchestrator" {
		t.Fatalf("unexpected messages: %v", msgs)
	}
}

func TestMessageToolRequiresBody(t *testing.T) {
	s, ctx := messageToolHarness(t)
	if _, err := s.messageTool(ctx, mustIdentity(t), `{"room":"abc"}`); err == nil {
		t.Fatal("expected error for missing body")
	}
}

func TestRoomInfoToolListsPeopleAgentsTools(t *testing.T) {
	s, ctx := messageToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "test space", "")
	if err != nil {
		t.Fatal(err)
	}
	// Add a second human member so people has more than the owner.
	alice := idFromHex(t, "00000000000000010000000000000002")
	now := time.Now().UTC()
	if err := s.R.CreateID(ctx, "accounts", alice, &account.Account{
		Entity: entity.Entity{ID: alice, CreatedAt: now, UpdatedAt: now},
		Kind:   account.KindUser, Handle: "alice", Status: account.StatusActive, MetadataID: alice,
	}); err != nil {
		t.Fatal(err)
	}
	memID, err := identity.New(s.K.NodeID())
	if err != nil {
		t.Fatal(err)
	}
	if err := s.R.CreateID(ctx, "memberships", memID, &membership.Membership{
		Entity:  entity.Entity{ID: memID, CreatedAt: now, UpdatedAt: now},
		SpaceID: sp.ID, MemberID: alice, Role: membership.RoleMember, JoinedAt: now,
	}); err != nil {
		t.Fatal(err)
	}

	out, err := s.roomInfoTool(ctx, sp.ID, `{}`)
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		People []map[string]any `json:"people"`
		Agents []map[string]any `json:"agents"`
		Tools  []map[string]any `json:"tools"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("bad tool output %q: %v", out, err)
	}
	if len(got.People) != 2 {
		t.Fatalf("expected 2 people (owner + alice), got %d: %s", len(got.People), out)
	}
	if len(got.Agents) != 1 {
		t.Fatalf("expected aseman in agents, got %d: %s", len(got.Agents), out)
	}
	if got.Agents[0]["name"] != "aseman" {
		t.Fatalf("unexpected agent: %v", got.Agents[0])
	}
	names := map[string]bool{}
	for _, tt := range got.Tools {
		names[tt["name"].(string)] = true
	}
	for _, want := range []string{"room_info", "message_send", "sandbox_exec", "proxy_list"} {
		if !names[want] {
			t.Fatalf("tool %q missing: %s", want, out)
		}
	}
}

func mustIdentity(t *testing.T) identity.ID {
	t.Helper()
	id, err := identity.Parse("00000000000000010000000000000099")
	if err != nil {
		t.Fatal(err)
	}
	return id
}
