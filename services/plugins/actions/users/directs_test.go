package users

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/pkg/crypto"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	"github.com/tradera/tradera/plugins/actions/support/metasvc"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/memory"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	dbmodel "github.com/tradera/tradera/plugins/testutil"
)

type dmFixture struct {
	t          *testing.T
	s          *Service
	ctx        context.Context
	actions    map[string]api.Action
	alice, bob api.Caller
}

func dmHarness(t *testing.T) *dmFixture {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := context.Background()
	for _, m := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"node_private_key": strings.Repeat("ab", 64), "admin_handle": "root"}})
	r := &repo.Repo{DB: db}
	s := &Service{K: k, R: r, M: &metasvc.Service{K: k, R: r}, L: logger.Global().Named("users")}
	f := &dmFixture{t: t, s: s, ctx: ctx, actions: map[string]api.Action{}}
	for i, handle := range []string{"alice", "bob"} {
		id := mustID(t, "0000000000000001000000000000000"+string(rune('1'+i)))
		acc := &account.Account{Entity: entity.Entity{ID: id}, Handle: handle, Kind: account.KindUser, Status: account.StatusActive}
		if err := s.R.CreateID(ctx, "accounts", id, acc); err != nil {
			t.Fatal(err)
		}
	}
	f.alice = api.Caller{ID: mustID(t, "00000000000000010000000000000001"), Kind: "user"}
	f.bob = api.Caller{ID: mustID(t, "00000000000000010000000000000002"), Kind: "user"}
	for _, a := range BuildActions(s) {
		f.actions[a.Meta().Name] = a
	}
	return f
}

func (f *dmFixture) call(name string, caller api.Caller, in map[string]any) (map[string]any, error) {
	f.t.Helper()
	body, _ := json.Marshal(in)
	res, err := f.actions[name].Handle(f.ctx, &api.ActionRequest{Caller: caller, Body: body})
	if err != nil {
		return nil, err
	}
	var out map[string]any
	_ = json.Unmarshal(res.Body, &out)
	return out, nil
}

func (f *dmFixture) must(name string, caller api.Caller, in map[string]any) map[string]any {
	f.t.Helper()
	out, err := f.call(name, caller, in)
	if err != nil {
		f.t.Fatalf("%s: %v", name, err)
	}
	return out
}

func (f *dmFixture) send(from, to api.Caller, body string) {
	f.t.Helper()
	f.must("dm_send", from, map[string]any{"to": to.ID.String(), "body": body})
	time.Sleep(2 * time.Millisecond) // distinct timestamps, in order
}

func bodies(out map[string]any) []string {
	var got []string
	for _, m := range out["messages"].([]any) {
		got = append(got, m.(map[string]any)["body"].(string))
	}
	return got
}

func TestDirectMessagesAreEncryptedAtRest(t *testing.T) {
	f := dmHarness(t)
	f.send(f.alice, f.bob, "the launch code is 1234")
	var rows []message.Direct
	if err := f.s.R.List(f.ctx, "directs", databaseAll(), &rows); err != nil || len(rows) != 1 {
		t.Fatalf("%v %d", err, len(rows))
	}
	if !strings.HasPrefix(rows[0].Body, crypto.SecretPrefix) || strings.Contains(rows[0].Body, "1234") {
		t.Fatalf("stored in the clear: %q", rows[0].Body)
	}
	if got := bodies(f.must("dm_list", f.bob, map[string]any{"peer": f.alice.ID.String()})); len(got) != 1 || got[0] != "the launch code is 1234" {
		t.Fatalf("read back: %v", got)
	}
}

func TestDeletingAChatIsForTheCallerOnly(t *testing.T) {
	f := dmHarness(t)
	f.send(f.alice, f.bob, "one")
	f.send(f.bob, f.alice, "two")
	f.must("dm_delete", f.alice, map[string]any{"peer": f.bob.ID.String()})
	time.Sleep(2 * time.Millisecond)
	if got := bodies(f.must("dm_list", f.alice, map[string]any{"peer": f.bob.ID.String()})); len(got) != 0 {
		t.Fatalf("alice still sees %v", got)
	}
	if threads := f.must("dm_threads", f.alice, nil)["threads"].([]any); len(threads) != 0 {
		t.Fatalf("the deleted chat is still listed: %v", threads)
	}
	if got := bodies(f.must("dm_list", f.bob, map[string]any{"peer": f.alice.ID.String()})); len(got) != 2 {
		t.Fatalf("bob lost his copy: %v", got)
	}
	// A new message brings the chat back for alice with only what is new.
	f.send(f.bob, f.alice, "three")
	if got := bodies(f.must("dm_list", f.alice, map[string]any{"peer": f.bob.ID.String()})); len(got) != 1 || got[0] != "three" {
		t.Fatalf("after a new message alice sees %v", got)
	}
	if threads := f.must("dm_threads", f.alice, nil)["threads"].([]any); len(threads) != 1 {
		t.Fatalf("threads: %v", threads)
	}
}

func TestBlockingStopsMessagesBothWays(t *testing.T) {
	f := dmHarness(t)
	f.send(f.alice, f.bob, "hi")
	f.must("dm_block", f.alice, map[string]any{"peer": f.bob.ID.String()})
	if _, err := f.call("dm_send", f.bob, map[string]any{"to": f.alice.ID.String(), "body": "hey"}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a blocked person could send: %v", err)
	}
	if _, err := f.call("dm_send", f.alice, map[string]any{"to": f.bob.ID.String(), "body": "hey"}); errs.CodeOf(err) != errs.CodePermission || !strings.Contains(err.Error(), "Unblock") {
		t.Fatalf("the blocker could send: %v", err)
	}
	if out := f.must("dm_list", f.alice, map[string]any{"peer": f.bob.ID.String()}); out["blocked"] != true || out["can_send"] != false {
		t.Fatalf("alice's view: %v", out)
	}
	if out := f.must("dm_list", f.bob, map[string]any{"peer": f.alice.ID.String()}); out["blocked"] != false || out["can_send"] != false {
		t.Fatalf("bob's view: %v", out)
	}
	f.must("dm_unblock", f.alice, map[string]any{"peer": f.bob.ID.String()})
	f.send(f.bob, f.alice, "hello again")
}

func TestUnreadAndSeen(t *testing.T) {
	f := dmHarness(t)
	f.send(f.alice, f.bob, "a")
	f.send(f.alice, f.bob, "b")
	threads := f.must("dm_threads", f.bob, nil)
	if threads["unread_total"] != 2.0 || threads["threads"].([]any)[0].(map[string]any)["unread"] != 2.0 {
		t.Fatalf("bob's unread: %v", threads)
	}
	if f.must("dm_threads", f.alice, nil)["unread_total"] != 0.0 {
		t.Fatal("the sender's own messages count as unread")
	}
	if out := f.must("dm_list", f.alice, map[string]any{"peer": f.bob.ID.String()}); out["peer_read_at"] != nil {
		t.Fatalf("seen before bob read: %v", out["peer_read_at"])
	}
	f.must("dm_read", f.bob, map[string]any{"peer": f.alice.ID.String()})
	if f.must("dm_threads", f.bob, nil)["unread_total"] != 0.0 {
		t.Fatal("still unread after reading")
	}
	if out := f.must("dm_list", f.alice, map[string]any{"peer": f.bob.ID.String()}); out["peer_read_at"] == nil {
		t.Fatal("alice does not see that bob read it")
	}
}

func databaseAll() database.Filter { return database.Filter{} }

func firstMessage(out map[string]any) map[string]any {
	msgs := out["messages"].([]any)
	return msgs[len(msgs)-1].(map[string]any)
}

func TestEditingAndTakingBackAMessage(t *testing.T) {
	f := dmHarness(t)
	f.send(f.alice, f.bob, "helo")
	id := firstMessage(f.must("dm_list", f.alice, map[string]any{"peer": f.bob.ID.String()}))["id"].(string)
	if _, err := f.call("dm_edit", f.bob, map[string]any{"id": id, "body": "hacked"}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("someone else edited it: %v", err)
	}
	f.must("dm_edit", f.alice, map[string]any{"id": id, "body": "hello"})
	m := firstMessage(f.must("dm_list", f.bob, map[string]any{"peer": f.alice.ID.String()}))
	if m["body"] != "hello" || m["edited_at"] == nil {
		t.Fatalf("bob sees %v", m)
	}
	var stored message.Direct
	_ = f.s.R.Get(f.ctx, "directs", mustID(t, id), &stored)
	if strings.Contains(stored.Body, "hello") {
		t.Fatal("the edit is stored in the clear")
	}
	f.send(f.bob, f.alice, "earlier reply")
	f.must("dm_send", f.bob, map[string]any{"to": f.alice.ID.String(), "body": "answer", "reply_to": id})
	f.must("dm_unsend", f.alice, map[string]any{"id": id})
	// Gone for both sides, with no placeholder, and no longer quoted.
	list := f.must("dm_list", f.bob, map[string]any{"peer": f.alice.ID.String()})
	if got := bodies(list); len(got) != 2 || got[0] != "earlier reply" || got[1] != "answer" {
		t.Fatalf("after unsending bob sees %v", got)
	}
	if m := firstMessage(list); m["reply_to"] != id || m["reply_deleted"] != true {
		t.Fatalf("the reply should say it answered a deleted message: %v", m)
	}
	if last := f.must("dm_threads", f.alice, nil)["threads"].([]any)[0].(map[string]any)["last"].(map[string]any); last["body"] != "answer" {
		t.Fatalf("preview: %v", last)
	}
	if _, err := f.call("dm_edit", f.alice, map[string]any{"id": id, "body": "again"}); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("a deleted message was edited: %v", err)
	}
}

func TestRepliesStayInTheirConversation(t *testing.T) {
	f := dmHarness(t)
	f.send(f.alice, f.bob, "question?")
	id := firstMessage(f.must("dm_list", f.bob, map[string]any{"peer": f.alice.ID.String()}))["id"].(string)
	f.must("dm_send", f.bob, map[string]any{"to": f.alice.ID.String(), "body": "answer", "reply_to": id})
	if m := firstMessage(f.must("dm_list", f.alice, map[string]any{"peer": f.bob.ID.String()})); m["reply_to"] != id {
		t.Fatalf("the reply lost its message: %v", m)
	}
	// A message of another conversation is not something to reply to here.
	carol := mustID(t, "00000000000000010000000000000003")
	if _, err := f.call("dm_send", f.bob, map[string]any{"to": carol.String(), "body": "x", "reply_to": id}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("replied across conversations: %v", err)
	}
}

func TestTypingShowsAndStopsWithTheMessage(t *testing.T) {
	f := dmHarness(t)
	f.must("dm_typing", f.alice, map[string]any{"peer": f.bob.ID.String()})
	if out := f.must("dm_list", f.bob, map[string]any{"peer": f.alice.ID.String()}); out["peer_typing"] != true {
		t.Fatalf("bob does not see alice typing: %v", out["peer_typing"])
	}
	if out := f.must("dm_list", f.alice, map[string]any{"peer": f.bob.ID.String()}); out["peer_typing"] != false {
		t.Fatal("alice sees herself typing")
	}
	f.send(f.alice, f.bob, "done typing")
	if out := f.must("dm_list", f.bob, map[string]any{"peer": f.alice.ID.String()}); out["peer_typing"] != false {
		t.Fatal("still typing after the message was sent")
	}
}

func TestADirectMessageNotificationOpensTheConversation(t *testing.T) {
	raw, err := apnsPayload(PushNote{Title: "Alice", Body: "hi", Kind: "dm", Peer: "acc-1"})
	if err != nil {
		t.Fatal(err)
	}
	var p struct {
		Aps  map[string]any    `json:"aps"`
		Body map[string]string `json:"body"`
	}
	_ = json.Unmarshal(raw, &p)
	if p.Body["kind"] != "dm" || p.Body["peer"] != "acc-1" || p.Aps["thread-id"] != "dm:acc-1" {
		t.Fatalf("payload: %s", raw)
	}
}

func TestDeletingAMessageForMeOnly(t *testing.T) {
	f := dmHarness(t)
	f.send(f.bob, f.alice, "keep")
	f.send(f.bob, f.alice, "hide me")
	id := firstMessage(f.must("dm_list", f.alice, map[string]any{"peer": f.bob.ID.String()}))["id"].(string)
	carol := api.Caller{ID: mustID(t, "00000000000000010000000000000003"), Kind: "user"}
	if _, err := f.call("dm_hide", carol, map[string]any{"id": id}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("an outsider hid it: %v", err)
	}
	f.must("dm_hide", f.alice, map[string]any{"id": id})
	f.must("dm_hide", f.alice, map[string]any{"id": id}) // twice is fine
	if got := bodies(f.must("dm_list", f.alice, map[string]any{"peer": f.bob.ID.String()})); len(got) != 1 || got[0] != "keep" {
		t.Fatalf("alice sees %v", got)
	}
	if got := bodies(f.must("dm_list", f.bob, map[string]any{"peer": f.alice.ID.String()})); len(got) != 2 {
		t.Fatalf("bob lost it: %v", got)
	}
	threads := f.must("dm_threads", f.alice, nil)
	last := threads["threads"].([]any)[0].(map[string]any)
	if last["last"].(map[string]any)["body"] != "keep" || threads["unread_total"] != 1.0 {
		t.Fatalf("alice's list: %v", threads)
	}
}

func TestSavedMessagesIsAConversationWithOneself(t *testing.T) {
	f := dmHarness(t)
	f.send(f.alice, f.alice, "buy milk")
	f.send(f.alice, f.alice, "call mum")
	if got := bodies(f.must("dm_list", f.alice, map[string]any{"peer": f.alice.ID.String()})); len(got) != 2 {
		t.Fatalf("notes shown %v (each once)", got)
	}
	threads := f.must("dm_threads", f.alice, nil)
	list := threads["threads"].([]any)
	if len(list) != 1 || list[0].(map[string]any)["saved"] != true || threads["unread_total"] != 0.0 {
		t.Fatalf("threads: %v", threads)
	}
	f.must("dm_read", f.alice, map[string]any{"peer": f.alice.ID.String()})
	if _, err := f.call("dm_block", f.alice, map[string]any{"peer": f.alice.ID.String()}); err == nil {
		t.Fatal("blocked oneself")
	}
}

func TestReportsReachTheAdminWithWhatWasReported(t *testing.T) {
	f := dmHarness(t)
	f.send(f.bob, f.alice, "buy my scam coin")
	id := firstMessage(f.must("dm_list", f.alice, map[string]any{"peer": f.bob.ID.String()}))["id"].(string)
	if _, err := f.call("dm_report", f.alice, map[string]any{"peer": f.bob.ID.String(), "message_id": id, "reason": "nope"}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("an unknown reason was taken: %v", err)
	}
	f.must("dm_report", f.alice, map[string]any{"peer": f.bob.ID.String(), "message_id": id, "reason": "scam", "note": "again"})
	f.must("dm_report", f.alice, map[string]any{"peer": f.bob.ID.String(), "reason": "spam"})
	// The sender deleting it afterwards does not erase the evidence.
	f.must("dm_unsend", f.bob, map[string]any{"id": id})

	if _, err := f.call("admin_chat_reports", f.alice, nil); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a non-admin read the reports: %v", err)
	}
	admin := api.Caller{ID: mustID(t, "00000000000000010000000000000009"), Kind: "user"}
	acc := &account.Account{Entity: entity.Entity{ID: admin.ID}, Handle: "root", Kind: account.KindUser, Status: account.StatusActive, Role: "admin"}
	if err := f.s.R.CreateID(f.ctx, "accounts", admin.ID, acc); err != nil {
		t.Fatal(err)
	}
	out := f.must("admin_chat_reports", admin, nil)
	reports := out["reports"].([]any)
	if out["open"] != 2.0 || len(reports) != 2 {
		t.Fatalf("reports: %v", out)
	}
	var msgReport map[string]any
	for _, r := range reports {
		if r.(map[string]any)["kind"] == "message" {
			msgReport = r.(map[string]any)
		}
	}
	ev := msgReport["evidence"].([]any)
	if len(ev) != 1 || ev[0].(map[string]any)["body"] != "buy my scam coin" || msgReport["reason"] != "scam" {
		t.Fatalf("evidence: %v", msgReport)
	}
	f.must("admin_chat_report_resolve", admin, map[string]any{"id": msgReport["id"], "status": "resolved"})
	if f.must("admin_chat_reports", admin, nil)["open"] != 1.0 {
		t.Fatal("still open after resolving")
	}
}

func TestAPinnedChatStaysOnTop(t *testing.T) {
	f := dmHarness(t)
	f.send(f.alice, f.alice, "note")
	time.Sleep(2 * time.Millisecond)
	f.send(f.bob, f.alice, "newer")
	order := func() []string {
		out := []string{}
		for _, th := range f.must("dm_threads", f.alice, nil)["threads"].([]any) {
			out = append(out, th.(map[string]any)["peer"].(map[string]any)["id"].(string))
		}
		return out
	}
	if got := order(); got[0] != f.bob.ID.String() {
		t.Fatalf("newest first: %v", got)
	}
	f.must("dm_pin", f.alice, map[string]any{"peer": f.alice.ID.String()})
	if got := order(); got[0] != f.alice.ID.String() {
		t.Fatalf("pinned first: %v", got)
	}
	// A pin is the pinner's own: bob's list is unchanged.
	if pinned := f.must("dm_threads", f.bob, nil)["threads"].([]any)[0].(map[string]any)["pinned_at"]; pinned != nil {
		t.Fatalf("bob sees a pin: %v", pinned)
	}
	f.must("dm_unpin", f.alice, map[string]any{"peer": f.alice.ID.String()})
	if got := order(); got[0] != f.bob.ID.String() {
		t.Fatalf("after unpin: %v", got)
	}
}

func TestAnAgentAnswersANoteOnlyInYourOwnNotes(t *testing.T) {
	f := dmHarness(t)
	agentAcc := mustID(t, "00000000000000010000000000000009")
	mine := &bot.Bot{Entity: entity.Entity{ID: mustID(t, "00000000000000010000000000000007")}, OwnerID: f.alice.ID, AccountID: agentAcc, Name: "Writer", Kind: bot.KindAgent}
	theirs := &bot.Bot{Entity: entity.Entity{ID: mustID(t, "00000000000000010000000000000008")}, OwnerID: f.bob.ID, AccountID: agentAcc, Name: "Unlisted", Kind: bot.KindAgent}
	for _, b := range []*bot.Bot{mine, theirs} {
		if err := f.s.R.CreateID(f.ctx, "bots", b.ID, b); err != nil {
			t.Fatal(err)
		}
	}
	note := f.must("dm_send", f.alice, map[string]any{"to": f.alice.ID.String(), "body": "@writer tidy this"})["id"].(string)
	toBob := f.must("dm_send", f.alice, map[string]any{"to": f.bob.ID.String(), "body": "@writer hi"})["id"].(string)
	if _, err := f.call("dm_agent_ask", f.alice, map[string]any{"message": toBob, "agent": mine.ID.String()}); err == nil {
		t.Fatal("an agent answered a chat with someone else")
	}
	if _, err := f.call("dm_agent_ask", f.alice, map[string]any{"message": note, "agent": theirs.ID.String()}); err == nil {
		t.Fatal("an unlisted agent of someone else answered")
	}
	f.must("dm_agent_ask", f.alice, map[string]any{"message": note, "agent": mine.ID.String()})
	// No spaces namespace here: the run fails, and the failure is answered.
	var answer map[string]any
	for i := 0; i < 100 && answer == nil; i++ {
		time.Sleep(10 * time.Millisecond)
		out := f.must("dm_list", f.alice, map[string]any{"peer": f.alice.ID.String()})
		for _, m := range out["messages"].([]any) {
			if mm := m.(map[string]any); mm["agent_id"] == agentAcc.String() {
				answer = mm
			}
		}
		if answer != nil && len(out["agents_working"].([]any)) != 0 {
			t.Fatalf("still working after the answer: %v", out["agents_working"])
		}
	}
	if answer == nil || answer["reply_to"] != note || answer["agent"] == nil || !strings.Contains(answer["body"].(string), "couldn't finish") {
		t.Fatalf("answer: %v", answer)
	}
	if _, err := f.call("dm_edit", f.alice, map[string]any{"id": answer["id"], "body": "forged"}); err == nil {
		t.Fatal("an agent's answer was edited")
	}
}
