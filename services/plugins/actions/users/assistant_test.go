package users

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/openviking"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
)

// assistantFixture is the chat harness with a stand-in for the built-in assistant.
type assistantFixture struct {
	*dmFixture
	rec     *bot.Bot
	mu      sync.Mutex
	turns   [][]map[string]string
	release chan struct{}
	answer  func(onText func(string)) (string, error)
}

func newAssistantFixture(t *testing.T) *assistantFixture {
	f := &assistantFixture{dmFixture: dmHarness(t), release: make(chan struct{})}
	f.rec = &bot.Bot{Entity: entity.Entity{ID: mustID(t, "00000000000000010000000000000007")}, AccountID: mustID(t, "00000000000000010000000000000009"),
		Name: "Aseman", Kind: bot.KindAgent, ImageRef: bot.BuiltinChatImage}
	f.s.assistantFn = func(context.Context) (*bot.Bot, error) { return f.rec, nil }
	f.s.answerFn = func(_ context.Context, _ identity.ID, _ *bot.Bot, turns []map[string]string, onText func(string)) (string, error) {
		f.mu.Lock()
		f.turns = append(f.turns, turns)
		answer := f.answer
		f.mu.Unlock()
		if answer == nil {
			return "an answer", nil
		}
		return answer(onText)
	}
	// In your own notes the same assistant answers as your Aseman: here with
	// no memory server and no rooms, and a decision model that says "answer".
	f.s.brainAnswerFn = func(ctx context.Context, person identity.ID, rec *bot.Bot, _ string, turns []map[string]string, onText func(string)) (string, error) {
		return f.s.answerFn(ctx, person, rec, turns, onText)
	}
	f.s.actFn = func(ctx context.Context, person identity.ID, _ string, turns []map[string]string, _ func(name, args string) string) (string, error) {
		return f.s.answerFn(ctx, person, f.rec, turns, func(string) {})
	}
	f.s.decideFn = func(context.Context, string) brainPlan { return brainPlan{decided: true} }
	f.s.memoryFn = func() *openviking.Client { return nil }
	f.s.roomsFn = func(context.Context, identity.ID) ([]brainRoom, error) { return nil, nil }
	return f
}

func (f *assistantFixture) lastTurns() []map[string]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.turns) == 0 {
		return nil
	}
	return f.turns[len(f.turns)-1]
}

// answerIn waits for the assistant's stored answer in the conversation, seen by `viewer`.
func (f *assistantFixture) answerIn(viewer api.Caller, peer api.Caller) map[string]any {
	f.t.Helper()
	for i := 0; i < 200; i++ {
		time.Sleep(10 * time.Millisecond)
		out := f.must("dm_list", viewer, map[string]any{"peer": peer.ID.String()})
		for _, m := range out["messages"].([]any) {
			if mm := m.(map[string]any); mm["agent_id"] == f.rec.AccountID.String() {
				return mm
			}
		}
	}
	f.t.Fatal("no answer arrived")
	return nil
}

func (f *assistantFixture) say(from, to api.Caller, body string) string {
	f.t.Helper()
	return f.must("dm_send", from, map[string]any{"to": to.ID.String(), "body": body})["id"].(string)
}

func TestTheAssistantAnswersANoteInYourOwnNotesAndTheAnswerIsStored(t *testing.T) {
	f := newAssistantFixture(t)
	note := f.say(f.alice, f.alice, "@aseman tidy this")
	f.must("dm_agent_ask", f.alice, map[string]any{"message": note})
	answer := f.answerIn(f.alice, f.alice)
	if answer["reply_to"] != note || answer["body"] != "an answer" || answer["agent"] == nil {
		t.Fatalf("answer: %v", answer)
	}
	if turns := f.lastTurns(); len(turns) != 1 || turns[0]["role"] != "user" || !strings.Contains(turns[0]["content"], "tidy this") {
		t.Fatalf("turns: %v", turns)
	}
	if strings.Contains(f.lastTurns()[0]["content"], "Alice:") {
		t.Fatalf("a person's own notes are not labelled with a name: %v", f.lastTurns())
	}
	if _, err := f.call("dm_edit", f.alice, map[string]any{"id": answer["id"], "body": "forged"}); err == nil {
		t.Fatal("the assistant's answer was edited")
	}
}

// While the answer is being written, both the chat's view and its text so far are there to show.
func TestTheAnswerCanBeSeenWhileItIsBeingWritten(t *testing.T) {
	f := newAssistantFixture(t)
	f.answer = func(onText func(string)) (string, error) {
		onText("Hel")
		<-f.release
		onText("Hello")
		return "Hello", nil
	}
	note := f.say(f.alice, f.alice, "@aseman hi")
	f.must("dm_agent_ask", f.alice, map[string]any{"message": note})
	var working []any
	for i := 0; i < 200; i++ {
		time.Sleep(10 * time.Millisecond)
		working = f.must("dm_list", f.alice, map[string]any{"peer": f.alice.ID.String()})["agents_working"].([]any)
		if len(working) == 1 && working[0].(map[string]any)["text"] == "Hel" {
			break
		}
	}
	if len(working) != 1 || working[0].(map[string]any)["text"] != "Hel" || working[0].(map[string]any)["message_id"] != note {
		t.Fatalf("while writing: %v", working)
	}
	close(f.release)
	f.answerIn(f.alice, f.alice)
	for i := 0; i < 100; i++ {
		if len(f.must("dm_list", f.alice, map[string]any{"peer": f.alice.ID.String()})["agents_working"].([]any)) == 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("still shown as writing after the answer was stored")
}

func TestInAPersonalChatBothPeopleSeeTheAnswerAndTheNamesInTheContext(t *testing.T) {
	f := newAssistantFixture(t)
	f.say(f.bob, f.alice, "should we book Friday?")
	mention := f.say(f.alice, f.bob, "@aseman what do you think")
	f.must("dm_agent_ask", f.alice, map[string]any{"message": mention})
	answer := f.answerIn(f.bob, f.alice) // read from bob's side
	if answer["reply_to"] != mention || answer["body"] != "an answer" {
		t.Fatalf("answer: %v", answer)
	}
	// Only the mention (and what it replies to) is sent: the earlier, unrelated message is not.
	turns := f.lastTurns()
	if len(turns) != 1 || !strings.HasPrefix(turns[0]["content"], "alice: ") || strings.Contains(turns[0]["content"], "Friday") {
		t.Fatalf("turns: %v", turns)
	}
}

func TestAReplyThreadIsContextButOnlyFromThisChat(t *testing.T) {
	f := newAssistantFixture(t)
	first := f.say(f.alice, f.bob, "draft a toast")
	f.must("dm_agent_ask", f.alice, map[string]any{"message": first})
	answer := f.answerIn(f.alice, f.bob)
	// A follow-up that replies to the assistant's answer sees the whole thread.
	reply := f.must("dm_send", f.alice, map[string]any{"to": f.bob.ID.String(), "body": "@aseman shorter", "reply_to": answer["id"]})["id"].(string)
	f.must("dm_agent_ask", f.alice, map[string]any{"message": reply})
	var turns []map[string]string
	for i := 0; i < 200 && len(turns) < 3; i++ {
		time.Sleep(10 * time.Millisecond)
		turns = f.lastTurns()
	}
	if len(turns) != 3 || turns[0]["role"] != "user" || turns[1]["role"] != "assistant" || turns[1]["content"] != "an answer" || !strings.Contains(turns[2]["content"], "shorter") {
		t.Fatalf("turns: %v", turns)
	}
}

func TestOnlyYourOwnMessagesAreAnswered(t *testing.T) {
	f := newAssistantFixture(t)
	theirs := f.say(f.bob, f.alice, "@aseman hi")
	if _, err := f.call("dm_agent_ask", f.alice, map[string]any{"message": theirs}); err == nil {
		t.Fatal("a message the caller did not write was answered")
	}
	own := f.say(f.alice, f.bob, "@aseman hi")
	f.must("dm_agent_ask", f.alice, map[string]any{"message": own})
	answer := f.answerIn(f.alice, f.bob)
	if _, err := f.call("dm_agent_ask", f.alice, map[string]any{"message": answer["id"]}); err == nil {
		t.Fatal("the assistant's own answer was answered")
	}
}

func TestABlockedChatGetsNoAnswers(t *testing.T) {
	f := newAssistantFixture(t)
	mention := f.say(f.alice, f.bob, "@aseman hi")
	f.must("dm_block", f.bob, map[string]any{"peer": f.alice.ID.String()})
	if _, err := f.call("dm_agent_ask", f.alice, map[string]any{"message": mention}); err == nil {
		t.Fatal("the assistant answered in a chat someone blocked")
	}
}

func TestAnOldAppsAgentChoiceIsIgnored(t *testing.T) {
	f := newAssistantFixture(t)
	note := f.say(f.alice, f.alice, "@writer hi")
	f.must("dm_agent_ask", f.alice, map[string]any{"message": note, "agent": "00000000000000010000000000000099"})
	if a := f.answerIn(f.alice, f.alice); a["agent_id"] != f.rec.AccountID.String() {
		t.Fatalf("answered by %v", a["agent_id"])
	}
}

func TestAFailureIsAnsweredToo(t *testing.T) {
	f := newAssistantFixture(t)
	f.answer = func(onText func(string)) (string, error) {
		onText("Half an ans")
		return "Half an ans", errors.New("the model broke")
	}
	note := f.say(f.alice, f.alice, "@aseman hi")
	f.must("dm_agent_ask", f.alice, map[string]any{"message": note})
	a := f.answerIn(f.alice, f.alice)
	body := a["body"].(string)
	if !strings.HasPrefix(body, "Half an ans") || !strings.Contains(body, "Something went wrong") || strings.Contains(body, "the model broke") {
		t.Fatalf("answer: %q", body)
	}
}

func TestAMessageIsNotAnsweredTwiceAtOnce(t *testing.T) {
	f := newAssistantFixture(t)
	f.answer = func(onText func(string)) (string, error) { <-f.release; return "done", nil }
	mention := f.say(f.alice, f.bob, "@aseman hi")
	f.must("dm_agent_ask", f.alice, map[string]any{"message": mention})
	if _, err := f.call("dm_agent_ask", f.alice, map[string]any{"message": mention}); err == nil {
		t.Fatal("the same message was answered twice at once")
	}
	close(f.release)
}

// An app that still asks for an answer to your own note is told yes: your
// Aseman already reads every note, and answers it once.
func TestAskingInYourOwnNotesAnswersOnce(t *testing.T) {
	f := newAssistantFixture(t)
	note := f.say(f.alice, f.alice, "@aseman hi")
	f.must("dm_agent_ask", f.alice, map[string]any{"message": note})
	f.answerIn(f.alice, f.alice)
	time.Sleep(50 * time.Millisecond)
	answers := 0
	for _, m := range f.must("dm_list", f.alice, map[string]any{"peer": f.alice.ID.String()})["messages"].([]any) {
		if m.(map[string]any)["agent_id"] != nil {
			answers++
		}
	}
	if answers != 1 {
		t.Fatalf("%d answers", answers)
	}
}

func TestTurnsLabelPeopleInAChatDropTheOldestPastTheBudgetAndKeepTheMention(t *testing.T) {
	a, b := mustID(t, "00000000000000010000000000000001"), mustID(t, "00000000000000010000000000000002")
	names := map[identity.ID]string{a: "Ann", b: "Bo"}
	chain := []threadMsg{
		{from: a, body: strings.Repeat("old ", 100)},
		{from: b, body: "middle"},
		{from: a, body: "@aseman decide"},
	}
	all := assistantTurns(chain, names, true, 10_000)
	if len(all) != 1 || !strings.Contains(all[0]["content"], "Ann: ") || !strings.Contains(all[0]["content"], "Bo: middle") {
		t.Fatalf("labels / merging of neighbours: %v", all)
	}
	tight := assistantTurns(chain, names, true, 40)
	if len(tight) != 1 || strings.Contains(tight[0]["content"], "old") || !strings.HasSuffix(tight[0]["content"], "@aseman decide") {
		t.Fatalf("the oldest should go and the mention stay: %v", tight)
	}
	huge := assistantTurns([]threadMsg{{from: a, body: strings.Repeat("x", 500)}}, names, false, 100)
	if len(huge) != 1 || len([]rune(huge[0]["content"])) > 60 {
		t.Fatalf("a mention past the budget is cut: %d", len(huge[0]["content"]))
	}
	roles := assistantTurns([]threadMsg{{from: a, body: "q"}, {from: a, agent: true, body: "a"}, {from: a, body: "q2"}}, names, false, 1000)
	if len(roles) != 3 || roles[1]["role"] != "assistant" {
		t.Fatalf("roles: %v", roles)
	}
}
