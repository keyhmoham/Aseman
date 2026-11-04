package spaces

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// callErr runs an action as caller and returns its error, if any.
func callErr(ctx context.Context, caller identity.ID, h func(context.Context, *api.ActionRequest) (*api.ActionResponse, error), body map[string]any) error {
	raw, _ := json.Marshal(body)
	_, err := h(ctx, &api.ActionRequest{Caller: api.Caller{ID: caller, Kind: "user"}, Body: raw})
	return err
}

func sendIn(t *testing.T, s *Service, ctx context.Context, caller, sp, room identity.ID, body string) string {
	t.Helper()
	var out struct {
		ID string `json:"message_id"`
	}
	callAs(t, ctx, caller, (&msgSendAction{s: s}).Handle, map[string]any{"space": sp.String(), "room": room.String(), "body": body}, &out)
	return out.ID
}

type listed struct {
	Messages   []map[string]any `json:"messages"`
	Typing     []map[string]any `json:"typing"`
	PeerSeenAt *time.Time       `json:"peer_seen_at"`
	Blocked    bool             `json:"blocked"`
	CanSend    *bool            `json:"can_send"`
	Saved      bool             `json:"saved"`
}

func listIn(t *testing.T, s *Service, ctx context.Context, caller, sp, room identity.ID) listed {
	t.Helper()
	var out listed
	callAs(t, ctx, caller, (&msgListAction{s: s}).Handle, map[string]any{"space": sp.String(), "room": room.String()}, &out)
	return out
}

// The sender changes or takes back their own message; the other side of the
// chat can do neither, and sees the change.
func TestDirectChatMessagesAreEditedAndTakenBackByTheirSender(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
	bob := directPerson(t, s, ctx, "00000000000000010000000000000002", "bob")
	sp, room, err := s.OpenDirect(ctx, alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	id := sendIn(t, s, ctx, bob, sp.ID, room.ID, "helo")
	if err := callErr(ctx, alice, s.messageEdit, map[string]any{"message": id, "body": "hacked"}); err == nil {
		t.Fatal("someone else changed a message")
	}
	var edited struct {
		Message map[string]any `json:"message"`
	}
	callAs(t, ctx, bob, s.messageEdit, map[string]any{"message": id, "body": "hello"}, &edited)
	if edited.Message["body"] != "hello" || edited.Message["edited_at"] == nil {
		t.Fatalf("edit: %v", edited.Message)
	}
	got := listIn(t, s, ctx, alice, sp.ID, room.ID)
	if len(got.Messages) != 1 || got.Messages[0]["body"] != "hello" || got.Messages[0]["edited_at"] == nil {
		t.Fatalf("the peer does not see the change: %v", got.Messages)
	}
	var history struct {
		Current  map[string]any   `json:"current"`
		Previous []map[string]any `json:"previous"`
	}
	callAs(t, ctx, alice, s.messageEdits, map[string]any{"message": id}, &history)
	if history.Current["body"] != "hello" || len(history.Previous) != 1 || history.Previous[0]["body"] != "helo" {
		t.Fatalf("edit history: %+v", history)
	}
	callAs(t, ctx, bob, s.messageEdit, map[string]any{"message": id, "body": "hello!"}, &edited)
	callAs(t, ctx, bob, s.messageEdits, map[string]any{"message": id}, &history)
	if history.Current["body"] != "hello!" || len(history.Previous) != 2 ||
		history.Previous[0]["body"] != "hello" || history.Previous[1]["body"] != "helo" {
		t.Fatalf("stacked edit history: %+v", history)
	}
	// Bob is a member, not a manager of the conversation: his own message is
	// still his to take back.
	if err := callErr(ctx, alice, (&msgDeleteAction{s: s}).Handle, map[string]any{"space": sp.ID.String(), "message": id}); err == nil {
		t.Fatal("the peer deleted someone else's message")
	}
	if err := callErr(ctx, bob, (&msgDeleteAction{s: s}).Handle, map[string]any{"space": sp.ID.String(), "message": id}); err != nil {
		t.Fatalf("the sender could not take back their message: %v", err)
	}
	if got := listIn(t, s, ctx, alice, sp.ID, room.ID); len(got.Messages) != 0 {
		t.Fatalf("a taken back message is still there: %v", got.Messages)
	}
}

// A blocked direct chat takes no messages either way; unblocking reopens it.
func TestBlockedDirectChatTakesNoMessages(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
	bob := directPerson(t, s, ctx, "00000000000000010000000000000002", "bob")
	sp, room, err := s.OpenDirect(ctx, alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	callAs(t, ctx, alice, s.directBlockSet, map[string]any{"space": sp.ID.String()}, &out)
	send := func(who identity.ID) error {
		return callErr(ctx, who, (&msgSendAction{s: s}).Handle, map[string]any{"space": sp.ID.String(), "room": room.ID.String(), "body": "hi"})
	}
	if send(bob) == nil || send(alice) == nil {
		t.Fatal("a blocked chat took a message")
	}
	if blocked, _ := s.DirectBlocked(ctx, bob, alice); !blocked {
		t.Fatal("users.dm_send would still deliver")
	}
	if err := s.PostDirect(ctx, bob, alice, "around the block", identity.ID{}); err == nil {
		t.Fatal("a mirrored direct message got through")
	}
	mine, theirs := listIn(t, s, ctx, alice, sp.ID, room.ID), listIn(t, s, ctx, bob, sp.ID, room.ID)
	if !mine.Blocked || mine.CanSend == nil || *mine.CanSend || theirs.Blocked || theirs.CanSend == nil || *theirs.CanSend {
		t.Fatalf("block state: alice %+v bob %+v", mine, theirs)
	}
	callAs(t, ctx, alice, s.directBlockSet, map[string]any{"space": sp.ID.String(), "blocked": false}, &out)
	if err := send(bob); err != nil {
		t.Fatalf("unblocked chat refused a message: %v", err)
	}
}

// Pinned chats come first; typing shows to the other side for a few seconds;
// the peer's read cursor is the caller's "seen".
func TestChatPinsTypingAndPeerReading(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
	bob := directPerson(t, s, ctx, "00000000000000010000000000000002", "bob")
	carol := directPerson(t, s, ctx, "00000000000000010000000000000003", "carol")
	withBob, bobRoom, err := s.OpenDirect(ctx, alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	withCarol, carolRoom, err := s.OpenDirect(ctx, alice, carol)
	if err != nil {
		t.Fatal(err)
	}
	sendIn(t, s, ctx, bob, withBob.ID, bobRoom.ID, "older")
	time.Sleep(5 * time.Millisecond)
	sendIn(t, s, ctx, carol, withCarol.ID, carolRoom.ID, "newer")
	if chats := chatsOf(t, s, ctx, alice); chats[0]["room_id"] != carolRoom.ID.String() {
		t.Fatalf("newest first: %v", chats)
	}
	var out map[string]any
	callAs(t, ctx, alice, s.chatPin, map[string]any{"space": withBob.ID.String(), "room": bobRoom.ID.String()}, &out)
	chats := chatsOf(t, s, ctx, alice)
	if chats[0]["room_id"] != bobRoom.ID.String() || chats[0]["pinned_at"] == nil {
		t.Fatalf("a pinned chat is not on top: %v", chats)
	}
	if other := chatsOf(t, s, ctx, bob); other[0]["pinned_at"] != nil {
		t.Fatal("one person's pin pinned it for the other")
	}
	callAs(t, ctx, alice, s.chatPin, map[string]any{"space": withBob.ID.String(), "room": bobRoom.ID.String(), "pinned": false}, &out)
	if chats := chatsOf(t, s, ctx, alice); chats[0]["room_id"] != carolRoom.ID.String() {
		t.Fatalf("unpinned chat stayed on top: %v", chats)
	}

	callAs(t, ctx, bob, s.typingSet, map[string]any{"space": withBob.ID.String(), "room": bobRoom.ID.String()}, &out)
	if got := listIn(t, s, ctx, alice, withBob.ID, bobRoom.ID); len(got.Typing) != 1 || got.Typing[0]["handle"] != "bob" {
		t.Fatalf("typing: %v", got.Typing)
	}
	if got := listIn(t, s, ctx, bob, withBob.ID, bobRoom.ID); len(got.Typing) != 0 {
		t.Fatal("people see themselves typing")
	}
	if chats := chatsOf(t, s, ctx, alice); chats[1]["typing"] != true {
		t.Fatalf("the chat list does not say bob is typing: %v", chats[1])
	}
	sendIn(t, s, ctx, bob, withBob.ID, bobRoom.ID, "done typing")
	if got := listIn(t, s, ctx, alice, withBob.ID, bobRoom.ID); len(got.Typing) != 0 {
		t.Fatal("still typing after sending")
	}

	if got := listIn(t, s, ctx, bob, withBob.ID, bobRoom.ID); got.PeerSeenAt != nil {
		t.Fatal("alice has read nothing yet")
	}
	read := time.Now().UTC()
	if _, err := s.MarkSeen(ctx, alice, withBob.ID, read); err != nil {
		t.Fatal(err)
	}
	if got := listIn(t, s, ctx, bob, withBob.ID, bobRoom.ID); got.PeerSeenAt == nil || got.PeerSeenAt.Before(read.Add(-time.Second)) {
		t.Fatalf("peer_seen_at: %v", got.PeerSeenAt)
	}
}

// Deleting a direct chat removes it for the caller only, until someone writes again.
func TestClearedDirectChatReturnsWithANewerMessage(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
	bob := directPerson(t, s, ctx, "00000000000000010000000000000002", "bob")
	sp, room, err := s.OpenDirect(ctx, alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	sendIn(t, s, ctx, bob, sp.ID, room.ID, "before")
	time.Sleep(5 * time.Millisecond)
	var out map[string]any
	callAs(t, ctx, alice, s.chatClear, map[string]any{"space": sp.ID.String()}, &out)
	if chats := chatsOf(t, s, ctx, alice); len(chats) != 0 {
		t.Fatalf("a deleted chat is listed: %v", chats)
	}
	if got := listIn(t, s, ctx, alice, sp.ID, room.ID); len(got.Messages) != 0 {
		t.Fatalf("deleted messages are shown: %v", got.Messages)
	}
	if got := listIn(t, s, ctx, bob, sp.ID, room.ID); len(got.Messages) != 1 {
		t.Fatal("deleting for oneself deleted it for the other side")
	}
	time.Sleep(5 * time.Millisecond)
	sendIn(t, s, ctx, bob, sp.ID, room.ID, "after")
	chats := chatsOf(t, s, ctx, alice)
	if len(chats) != 1 {
		t.Fatalf("the chat did not come back: %v", chats)
	}
	if got := listIn(t, s, ctx, alice, sp.ID, room.ID); len(got.Messages) != 1 || got.Messages[0]["body"] != "after" {
		t.Fatalf("messages after clearing: %v", got.Messages)
	}
	if err := callErr(ctx, alice, s.chatClear, map[string]any{"space": s.mustProject(t, ctx, alice).String()}); err == nil {
		t.Fatal("a project room was cleared like a direct chat")
	}
}

func (s *Service) mustProject(t *testing.T, ctx context.Context, owner identity.ID) identity.ID {
	t.Helper()
	sp, err := s.CreateSpace(ctx, owner, "project", "")
	if err != nil {
		t.Fatal(err)
	}
	return sp.ID
}

// Aseman (formerly Saved Messages) is a direct chat with oneself: always the
// same one, listed among chats, with no one to block.
func TestSavedMessagesIsADirectChatWithOneself(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
	sp, room, err := s.OpenDirect(ctx, alice, alice)
	if err != nil {
		t.Fatal(err)
	}
	again, _, err := s.OpenDirect(ctx, alice, alice)
	if err != nil || again.ID != sp.ID || !sp.Direct {
		t.Fatalf("aseman chat: %v", err)
	}
	if sp.Name != "Aseman" {
		t.Fatalf("aseman space name: %q", sp.Name)
	}
	sendIn(t, s, ctx, alice, sp.ID, room.ID, "remember the milk")
	chats := chatsOf(t, s, ctx, alice)
	if len(chats) != 1 || chats[0]["saved"] != true {
		t.Fatalf("aseman chat row: %v", chats)
	}
	if got := listIn(t, s, ctx, alice, sp.ID, room.ID); !got.Saved || len(got.Messages) != 1 {
		t.Fatalf("aseman list: %+v", got)
	}
	if err := callErr(ctx, alice, s.directBlockSet, map[string]any{"space": sp.ID.String()}); err == nil {
		t.Fatal("blocked oneself")
	}
}

// Opening a Direct with the built-in Aseman assistant lands in the personal
// Aseman self-chat — never a separate person↔assistant conversation.
func TestOpenDirectWithBuiltinAssistantUsesAsemanChat(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
	now := time.Now().UTC()
	assistantAcc := idFromHex(t, "00000000000000010000000000000009")
	if err := s.R.CreateID(ctx, "accounts", assistantAcc, &account.Account{
		Entity: entity.Entity{ID: assistantAcc, CreatedAt: now, UpdatedAt: now},
		Kind:   account.KindBot, Handle: "aseman-chat", Status: account.StatusActive, MetadataID: assistantAcc,
	}); err != nil {
		t.Fatal(err)
	}
	botID := idFromHex(t, "0000000000000001000000000000000a")
	if err := s.R.CreateID(ctx, "bots", botID, &bot.Bot{
		Entity:  entity.Entity{ID: botID, CreatedAt: now, UpdatedAt: now},
		OwnerID: assistantAcc, AccountID: assistantAcc, Name: "Aseman", Kind: bot.KindAgent,
		VMType: bot.VMTypeHarness, Status: bot.StatusRunning, ImageRef: bot.BuiltinChatImage,
	}); err != nil {
		t.Fatal(err)
	}
	saved, _, err := s.OpenDirect(ctx, alice, alice)
	if err != nil {
		t.Fatal(err)
	}
	opened, _, err := s.OpenDirect(ctx, alice, assistantAcc)
	if err != nil || opened.ID != saved.ID || !opened.Direct {
		t.Fatalf("builtin open: space=%v err=%v", opened, err)
	}
	chats := chatsOf(t, s, ctx, alice)
	if len(chats) != 1 || chats[0]["saved"] != true {
		t.Fatalf("inbox after builtin open: %v", chats)
	}
}

// Personal Aseman replies land in the Aseman chat as the assistant — not in a
// separate person↔assistant Direct that would only ever hold the assistant side.
func TestPostSavedAnswerKeepsTheThreadInSavedMessages(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
	assistant := directPerson(t, s, ctx, "00000000000000010000000000000009", "aseman-chat")
	sp, room, err := s.OpenDirect(ctx, alice, alice)
	if err != nil {
		t.Fatal(err)
	}
	sendIn(t, s, ctx, alice, sp.ID, room.ID, "what is on my plate today?")
	directID := identity.MustParse("00000000000000010000000000000a01")
	if err := s.PostSavedAnswer(ctx, alice, assistant, "You have the launch review at 3.", directID); err != nil {
		t.Fatal(err)
	}
	got := listIn(t, s, ctx, alice, sp.ID, room.ID)
	if len(got.Messages) != 2 {
		t.Fatalf("saved thread: %+v", got)
	}
	// Newest first.
	if got.Messages[0]["body"] != "You have the launch review at 3." || got.Messages[0]["sender_id"] != assistant.String() {
		t.Fatalf("assistant reply: %+v", got.Messages[0])
	}
	if got.Messages[1]["body"] != "what is on my plate today?" || got.Messages[1]["sender_id"] != alice.String() {
		t.Fatalf("user note: %+v", got.Messages[1])
	}
	if got.Messages[0]["direct_id"] != directID.String() {
		t.Fatalf("direct id stamp: %+v", got.Messages[0])
	}
	// Must not have opened a separate Direct with the assistant.
	for _, chat := range chatsOf(t, s, ctx, alice) {
		if chat["saved"] == true {
			continue
		}
		t.Fatalf("unexpected non-saved chat: %v", chat)
	}
}

// A report copies what was written, once per person and message, and only
// the node's admins read the reports.
func TestReportedMessageKeepsItsEvidenceForTheAdmins(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
	bob := directPerson(t, s, ctx, "00000000000000010000000000000002", "bob")
	sp, room, err := s.OpenDirect(ctx, alice, bob)
	if err != nil {
		t.Fatal(err)
	}
	sendIn(t, s, ctx, alice, sp.ID, room.ID, "hi bob")
	bad := sendIn(t, s, ctx, bob, sp.ID, room.ID, "send me your password")
	report := map[string]any{"space": sp.ID.String(), "room": room.ID.String(), "message": bad, "reason": "scam"}
	if err := callErr(ctx, bob, s.messageReport, report); err == nil {
		t.Fatal("a person reported their own message")
	}
	if err := callErr(ctx, alice, s.messageReport, map[string]any{"space": sp.ID.String(), "room": room.ID.String(), "reason": "boring"}); err == nil {
		t.Fatal("an unknown reason was accepted")
	}
	var out map[string]any
	callAs(t, ctx, alice, s.messageReport, report, &out)
	report["reason"] = "abuse"
	callAs(t, ctx, alice, s.messageReport, report, &out)
	var rows []ChatReport
	if err := s.R.List(ctx, "chat_reports", database.Filter{}, &rows); err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Reason != "abuse" || rows[0].AccusedID != bob.String() || rows[0].Status != reportOpen {
		t.Fatalf("reports: %+v", rows)
	}
	var evidence []map[string]any
	_ = json.Unmarshal([]byte(rows[0].Evidence), &evidence)
	if len(evidence) != 2 || evidence[1]["body"] != "send me your password" {
		t.Fatalf("evidence: %v", evidence)
	}
	// Taking the message back does not take back the evidence.
	if err := callErr(ctx, bob, (&msgDeleteAction{s: s}).Handle, map[string]any{"space": sp.ID.String(), "message": bad}); err != nil {
		t.Fatal(err)
	}
	var msg message.Message
	if err := s.R.Get(ctx, "messages", identity.MustParse(bad), &msg); err == nil {
		t.Fatal("the message was not deleted")
	}
	if err := callErr(ctx, alice, s.adminChatReports, map[string]any{}); err == nil {
		t.Fatal("a person who is not an admin read the reports")
	}
}
