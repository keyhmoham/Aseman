package spaces

import (
	"context"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	"github.com/tradera/tradera/plugins/actions/spaces/models/permission"
)

func directPerson(t *testing.T, s *Service, ctx context.Context, hex, handle string) identity.ID {
	t.Helper()
	id := idFromHex(t, hex)
	now := time.Now().UTC()
	if err := s.R.CreateID(ctx, "accounts", id, &account.Account{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		Kind: account.KindUser, Handle: handle, Status: account.StatusActive}); err != nil {
		t.Fatal(err)
	}
	return id
}

func chatsOf(t *testing.T, s *Service, ctx context.Context, caller identity.ID) []map[string]any {
	t.Helper()
	var out struct {
		Chats []map[string]any `json:"chats"`
	}
	callAs(t, ctx, caller, s.chatList, map[string]any{}, &out)
	return out.Chats
}

func projectsOf(t *testing.T, s *Service, ctx context.Context, caller identity.ID, kind string) []map[string]any {
	t.Helper()
	var out struct {
		Spaces []map[string]any `json:"spaces"`
	}
	callAs(t, ctx, caller, (&spaceListAction{s: s}).Handle, map[string]any{"kind": kind}, &out)
	return out.Spaces
}

// A direct conversation is one hidden single-room space per pair: either side
// opens the same one, the earlier direct messages come along, and it lists
// among chats but not among projects.
func TestDirectConversationIsOneHiddenRoomPerPair(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
	bob := directPerson(t, s, ctx, "00000000000000010000000000000002", "bob")
	oldID := idFromHex(t, "00000000000000010000000000000009")
	sent := time.Now().UTC().Add(-time.Hour).Truncate(time.Millisecond)
	if err := s.R.CreateID(ctx, "directs", oldID, &message.Direct{Entity: entity.Entity{ID: oldID, CreatedAt: sent, UpdatedAt: sent},
		From: bob, To: alice, Body: "hi from before", SentAt: sent}); err != nil {
		t.Fatal(err)
	}

	sp, room, err := s.OpenDirect(ctx, alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	if !sp.Direct {
		t.Fatal("a direct conversation is marked direct")
	}
	again, againRoom, err := s.OpenDirect(ctx, bob, alice)
	if err != nil || again.ID != sp.ID || againRoom.ID != room.ID {
		t.Fatalf("the other side opened another conversation: %v", err)
	}
	if s.traderaAccount(ctx) != (identity.ID{}) {
		if _, err := s.SpaceMembership(ctx, sp.ID, s.traderaAccount(ctx)); err == nil {
			t.Fatal("the tradera lead joined a direct conversation")
		}
	}
	if err := s.Can(ctx, sp.ID, room.ID, bob, permission.RoomSend); err != nil {
		t.Fatalf("the peer cannot write: %v", err)
	}

	chats := chatsOf(t, s, ctx, alice)
	if len(chats) != 1 {
		t.Fatalf("chats: %v", chats)
	}
	chat := chats[0]
	if chat["kind"] != "direct" || chat["room_id"] != room.ID.String() {
		t.Fatalf("chat row: %v", chat)
	}
	if peer, _ := chat["peer"].(map[string]any); peer["handle"] != "bob" {
		t.Fatalf("peer: %v", chat["peer"])
	}
	if last, _ := chat["last"].(map[string]any); last["body"] != "hi from before" {
		t.Fatalf("earlier direct messages were not imported: %v", chat["last"])
	}

	projects := projectsOf(t, s, ctx, alice, "")
	if len(projects) != 0 {
		t.Fatalf("a direct conversation listed among projects: %v", projects)
	}
	all := projectsOf(t, s, ctx, alice, "all")
	if len(all) != 1 {
		t.Fatalf("kind all: %v", all)
	}
}

func TestDirectConversationNeedsSomeoneElse(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
	if _, _, err := s.OpenDirect(ctx, alice, alice); err == nil {
		t.Fatal("a conversation with oneself was opened")
	}
	if _, _, err := s.OpenDirect(ctx, alice, idFromHex(t, "00000000000000010000000000000077")); err == nil {
		t.Fatal("a conversation with an unknown account was opened")
	}
}

// Writing to an agent in its direct conversation addresses it without an
// explicit mention; the agent's own messages address nobody.
func TestDirectConversationWithAnAgentAddressesIt(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
	project, err := s.CreateSpace(ctx, alice, "project", "")
	if err != nil {
		t.Fatal(err)
	}
	agent := addDevBotMember(t, s, ctx, project.ID)
	sp, _, err := s.OpenDirect(ctx, alice, agent)
	if err != nil {
		t.Fatal(err)
	}
	if owner, err := s.SpaceMembership(ctx, sp.ID, alice); err != nil || !owner.IsOwner() {
		t.Fatalf("the person owns the conversation: %v", err)
	}
	got := s.directMentions(ctx, sp.ID, alice, nil)
	if len(got) != 1 || got[0] != agent.String() {
		t.Fatalf("mentions: %v", got)
	}
	if got := s.directMentions(ctx, sp.ID, agent, nil); len(got) != 0 {
		t.Fatalf("the agent addressed itself: %v", got)
	}
	if got := s.directMentions(ctx, project.ID, alice, nil); len(got) != 0 {
		t.Fatalf("a project room gained mentions: %v", got)
	}
}
