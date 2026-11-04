package spaces

import (
	"context"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/spaces/models/permission"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
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
	if s.asemanAccount(ctx) != (identity.ID{}) {
		if _, err := s.SpaceMembership(ctx, sp.ID, s.asemanAccount(ctx)); err == nil {
			t.Fatal("the aseman lead joined a direct conversation")
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

// (A conversation with oneself is Saved Messages: see chats_test.go.)
func TestDirectConversationNeedsAnAccountOfThisNode(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
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

// The founding agent of a person↔agent Direct cannot be removed; an additional
// subagent installed into that chat can.
func TestDirectChatCannotRemoveFoundingAgentPeer(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
	project, err := s.CreateSpace(ctx, alice, "project", "")
	if err != nil {
		t.Fatal(err)
	}
	agent := addDevBotMember(t, s, ctx, project.ID)
	sp, room, err := s.OpenDirect(ctx, alice, agent)
	if err != nil {
		t.Fatal(err)
	}
	if err := callErr(ctx, alice, (&botRemoveAction{s: s}).Handle, map[string]any{
		"space": sp.ID.String(), "room": room.ID.String(), "bot": agent.String(),
	}); err == nil {
		t.Fatal("removed the founding agent peer")
	}
	sub := addAgent(t, s, ctx, project.ID, "helper", "helper-vm")
	if err := s.AddBot(ctx, alice, sp.ID, identity.ID{}, sub.AccountID); err != nil {
		t.Fatal(err)
	}
	if err := callErr(ctx, alice, (&botRemoveAction{s: s}).Handle, map[string]any{
		"space": sp.ID.String(), "bot": sub.ID.String(),
	}); err != nil {
		t.Fatalf("could not remove a subagent: %v", err)
	}
	if _, err := s.SpaceMembership(ctx, sp.ID, agent); err != nil {
		t.Fatal("founding agent peer was removed")
	}
	if _, err := s.SpaceMembership(ctx, sp.ID, sub.AccountID); err == nil {
		t.Fatal("subagent is still a member")
	}
}

// Direct chats work on the person's own computer: whoever's work it is (the
// person, or the agent working for them in their run) uses that person's home
// workspace computer, made the first time it is needed; projects keep theirs.
func TestDirectChatsWorkOnThePersonsOwnComputer(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
	bob := directPerson(t, s, ctx, "00000000000000010000000000000002", "bob")
	project, err := s.CreateSpace(ctx, alice, "project", "")
	if err != nil {
		t.Fatal(err)
	}
	agent := addDevBotMember(t, s, ctx, project.ID)
	dm, _, err := s.OpenDirect(ctx, alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	aliceBox := s.computerOf(ctx, dm.ID, alice)
	home, err := s.HomeSpace(ctx, alice)
	if err != nil || aliceBox != home.ID {
		t.Fatalf("alice works on %v, her home is %v (%v)", aliceBox, home, err)
	}
	if again := s.computerOf(ctx, dm.ID, alice); again != aliceBox {
		t.Fatal("a second home workspace was made")
	}
	bobBox := s.computerOf(ctx, dm.ID, bob)
	if bobBox == aliceBox || bobBox == dm.ID {
		t.Fatalf("bob's work in the same chat is on %v", bobBox)
	}
	// An agent works on the computer of the person whose run it is in.
	inBobsRun := vmm.WithExecution(ctx, vmm.Execution{ActorID: bob.String()})
	if got := s.computerOf(inBobsRun, dm.ID, agent); got != bobBox {
		t.Fatalf("an agent in bob's run works on %v", got)
	}
	if got := s.personalSandboxSpace(helper.WithActor(ctx, agent), dm.ID); got != dm.ID {
		t.Fatalf("an agent working for nobody got a personal computer: %v", got)
	}
	if got := s.computerOf(ctx, project.ID, alice); got != project.ID {
		t.Fatalf("a project's work moved to %v", got)
	}
	if _, err := s.HomeSpace(ctx, agent); err == nil {
		t.Fatal("an agent was given a home workspace")
	}
}
