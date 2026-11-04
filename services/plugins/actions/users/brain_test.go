package users

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
)

// fakeMemory is a person's memory in the agent runtime, recording its use.
type fakeMemory struct {
	mu       sync.Mutex
	notes    map[string]string // person → notes
	recalled []string
	queries  []string
	learned  []string // person|said
}

func newFakeMemory() *fakeMemory { return &fakeMemory{notes: map[string]string{}} }

func (m *fakeMemory) PersonNotes(_ context.Context, person string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.notes[person], nil
}

func (m *fakeMemory) PersonSetNotes(_ context.Context, person, content string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.notes[person] = content
	return nil
}

func (m *fakeMemory) PersonRecall(_ context.Context, _ string, query string, _ int) ([]string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.queries = append(m.queries, query)
	return m.recalled, nil
}

func (m *fakeMemory) PersonLearn(_ context.Context, person, said, _ string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.learned = append(m.learned, person+"|"+said)
}

func (m *fakeMemory) note(person string) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.notes[person]
}

// brainFixture is the assistant harness with a memory server and a brain whose
// decisions and answers the test chooses.
type brainFixture struct {
	*assistantFixture
	memory *fakeMemory
	plan   brainPlan
	briefs []string
	rooms  []brainRoom
	lines  map[string][]brainLine
}

func newBrainFixture(t *testing.T) *brainFixture {
	f := &brainFixture{assistantFixture: newAssistantFixture(t), plan: brainPlan{decided: true}, lines: map[string][]brainLine{}}
	f.memory = newFakeMemory()
	f.s.memoryFn = func() vmm.PersonMemory { return f.memory }
	f.s.decideFn = func(context.Context, string) brainPlan {
		f.mu.Lock()
		defer f.mu.Unlock()
		return f.plan
	}
	f.s.brainAnswerFn = func(ctx context.Context, person identity.ID, rec *bot.Bot, brief string, turns []map[string]string, onText func(string)) (string, error) {
		f.mu.Lock()
		f.briefs = append(f.briefs, brief)
		f.mu.Unlock()
		return f.s.answerFn(ctx, person, rec, turns, onText)
	}
	f.s.roomsFn = func(context.Context, identity.ID) ([]brainRoom, error) { return f.rooms, nil }
	f.s.linesFn = func(_ context.Context, _ identity.ID, space string) []brainLine { return f.lines[space] }
	forgetCachedNotes(f.alice.ID)
	return f
}

func (f *brainFixture) note(body string) map[string]any {
	f.t.Helper()
	id := f.say(f.alice, f.alice, body)
	for _, m := range f.must("dm_list", f.alice, map[string]any{"peer": f.alice.ID.String()})["messages"].([]any) {
		if mm := m.(map[string]any); mm["id"] == id {
			return mm
		}
	}
	f.t.Fatal("the note is not there")
	return nil
}

// settled waits until nothing is being written in the notes any more.
func (f *brainFixture) settled() map[string]any {
	f.t.Helper()
	for i := 0; i < 200; i++ {
		out := f.must("dm_list", f.alice, map[string]any{"peer": f.alice.ID.String()})
		if len(out["agents_working"].([]any)) == 0 {
			return out
		}
		time.Sleep(10 * time.Millisecond)
	}
	f.t.Fatal("still working")
	return nil
}

func (f *brainFixture) noteState(out map[string]any, id any) map[string]any {
	for _, m := range out["messages"].([]any) {
		if mm := m.(map[string]any); mm["id"] == id {
			return mm
		}
	}
	return nil
}

func agentAnswers(out map[string]any) int {
	n := 0
	for _, m := range out["messages"].([]any) {
		if m.(map[string]any)["agent_id"] != nil {
			n++
		}
	}
	return n
}

func TestANoteToKeepIsKeptWithoutAnAnswer(t *testing.T) {
	f := newBrainFixture(t)
	f.plan = brainPlan{decided: true, save: true}
	n := f.note("milk, eggs, bread")
	// Keeping it happens after the note is stored: wait for the mark.
	out := f.settled()
	for i := 0; i < 200 && f.noteState(out, n["id"])["brain"] != "saved"; i++ {
		time.Sleep(10 * time.Millisecond)
		out = f.settled()
	}
	if agentAnswers(out) != 0 {
		t.Fatal("a note to keep was answered")
	}
	if f.noteState(out, n["id"])["brain"] != "saved" {
		t.Fatalf("the note is not marked kept: %v", f.noteState(out, n["id"]))
	}
	// It is still remembered.
	time.Sleep(20 * time.Millisecond)
	f.memory.mu.Lock()
	defer f.memory.mu.Unlock()
	if len(f.memory.learned) == 0 || !strings.HasPrefix(f.memory.learned[0], f.alice.ID.String()+"|") {
		t.Fatalf("the note was not given to the person's own memory: %v", f.memory.learned)
	}
}

func TestALinkIsKeptWithoutAskingTheDecisionModel(t *testing.T) {
	f := newBrainFixture(t)
	asked := false
	f.s.decideFn = func(context.Context, string) brainPlan { asked = true; return brainPlan{decided: true} }
	n := f.note("https://example.com/article")
	out := f.settled()
	if asked || agentAnswers(out) != 0 || f.noteState(out, n["id"])["brain"] != "saved" {
		t.Fatalf("asked %v, note %v", asked, f.noteState(out, n["id"]))
	}
}

func TestNamingAsemanAlwaysGetsAnAnswer(t *testing.T) {
	f := newBrainFixture(t)
	f.plan = brainPlan{decided: true, save: true}
	f.note("@aseman milk, eggs")
	f.answerIn(f.alice, f.alice)
}

func TestAQuestionIsAnsweredWithWhatItKnowsAndRecalls(t *testing.T) {
	f := newBrainFixture(t)
	f.memory.notes[f.alice.ID.String()] = "- I am vegetarian (2026-10-01)\n"
	f.memory.recalled = []string{"Alice's sister Sara visits in November."}
	f.note("what should I cook for Sara?")
	answer := f.answerIn(f.alice, f.alice)
	if answer["body"] != "an answer" {
		t.Fatalf("answer %v", answer)
	}
	f.mu.Lock()
	brief := f.briefs[len(f.briefs)-1]
	f.mu.Unlock()
	if !strings.Contains(brief, "I am vegetarian") {
		t.Fatalf("what it knows is not in the brief: %q", brief)
	}
	turns := f.lastTurns()
	last := turns[len(turns)-1]["content"]
	if !strings.Contains(last, "Sara visits in November") || !strings.HasSuffix(last, "what should I cook for Sara?") {
		t.Fatalf("recall is not with the message: %q", last)
	}
	f.memory.mu.Lock()
	query := f.memory.queries[0]
	f.memory.mu.Unlock()
	if !strings.Contains(query, "what should I cook for Sara?") {
		t.Fatalf("recall query %q", query)
	}
}

func TestALastingFactIsRememberedButNotASecret(t *testing.T) {
	f := newBrainFixture(t)
	f.plan = brainPlan{decided: true, save: true, remember: true}
	f.note("My daughter Mina starts school in September")
	f.settled()
	f.note("wifi password is hunter2")
	f.settled()
	notes := f.memory.note(f.alice.ID.String())
	if !strings.Contains(notes, "My daughter Mina starts school in September") {
		t.Fatalf("not remembered: %q", notes)
	}
	if strings.Contains(notes, "hunter2") {
		t.Fatalf("a secret went into what it knows: %q", notes)
	}
}

func TestWithoutADecisionModelTheAnswerModelMayKeepANoteSilently(t *testing.T) {
	f := newBrainFixture(t)
	f.plan = brainPlan{} // no decision model
	f.answer = func(onText func(string)) (string, error) {
		onText("<sav")
		onText("<saved>")
		return "<saved>", nil
	}
	n := f.note("call the plumber thursday")
	out := f.settled()
	if agentAnswers(out) != 0 || f.noteState(out, n["id"])["brain"] != "saved" {
		t.Fatalf("answers %d, note %v", agentAnswers(out), f.noteState(out, n["id"]))
	}
}

func TestWhileDecidingNothingIsShownButTheAppKnowsToLook(t *testing.T) {
	f := newBrainFixture(t)
	release := make(chan struct{})
	f.s.decideFn = func(context.Context, string) brainPlan { <-release; return brainPlan{decided: true, save: true} }
	f.say(f.alice, f.alice, "a thought")
	working := f.must("dm_list", f.alice, map[string]any{"peer": f.alice.ID.String()})["agents_working"].([]any)
	if len(working) != 1 || working[0].(map[string]any)["deciding"] != true {
		t.Fatalf("working %v", working)
	}
	close(release)
	f.settled()
}

func TestRoomsAreReadOnlyWhenAllowed(t *testing.T) {
	f := newBrainFixture(t)
	mine, theirs := "00000000000000010000000000000a01", "00000000000000010000000000000a02"
	f.rooms = []brainRoom{{ID: mine, Name: "Launch", Owner: true}, {ID: theirs, Name: "Acme team"}}
	now := time.Now().UTC()
	f.lines[mine] = []brainLine{{From: "lead", Body: "pricing page is done", At: now}}
	f.lines[theirs] = []brainLine{{From: "bob", Body: "the Acme budget is secret", At: now}}
	f.plan = brainPlan{decided: true, rooms: true}

	rooms := f.must("brain_rooms", f.alice, map[string]any{})["rooms"].([]any)
	if len(rooms) != 2 || rooms[0].(map[string]any)["allowed"] != true || rooms[1].(map[string]any)["allowed"] != false {
		t.Fatalf("defaults: %v", rooms)
	}
	f.note("how is the launch going?")
	f.answerIn(f.alice, f.alice)
	last := f.lastTurns()[len(f.lastTurns())-1]["content"]
	if !strings.Contains(last, "pricing page is done") || strings.Contains(last, "Acme budget") {
		t.Fatalf("rooms read: %q", last)
	}

	f.must("brain_room_set", f.alice, map[string]any{"space": theirs, "allowed": true})
	f.must("brain_room_set", f.alice, map[string]any{"space": mine, "allowed": false})
	rooms = f.must("brain_rooms", f.alice, map[string]any{})["rooms"].([]any)
	if rooms[0].(map[string]any)["allowed"] != false || rooms[1].(map[string]any)["allowed"] != true {
		t.Fatalf("choices: %v", rooms)
	}
	if _, err := f.call("brain_room_set", f.alice, map[string]any{"space": "00000000000000010000000000000a03", "allowed": true}); err == nil {
		t.Fatal("a room the person is not in was allowed")
	}
}

func TestThePersonSeesAndEditsWhatItKnows(t *testing.T) {
	f := newBrainFixture(t)
	f.must("brain_memory_set", f.alice, map[string]any{"notes": "- I live in London\n"})
	got := f.must("brain_memory_get", f.alice, map[string]any{})
	if got["available"] != true || got["notes"] != "- I live in London\n" {
		t.Fatalf("got %v", got)
	}
	// Another person's memory is their own.
	if other := f.must("brain_memory_get", f.bob, map[string]any{}); other["notes"] != "" {
		t.Fatalf("bob sees %v", other)
	}
}

func TestBrainPlanFollowsTheDecisionModelOnlyWhenSure(t *testing.T) {
	sure := brainPlanOf(map[string]any{
		"mode":     map[string]any{"choice": "save", "probabilities": map[string]any{"save": 0.92, "answer": 0.08}},
		"remember": map[string]any{"probability": 0.75},
		"rooms":    map[string]any{"probability": 0.2},
	})
	if !sure.decided || !sure.save || !sure.remember || sure.rooms {
		t.Fatalf("sure: %+v", sure)
	}
	unsure := brainPlanOf(map[string]any{"mode": map[string]any{"choice": "save", "probabilities": map[string]any{"save": 0.6}}})
	if unsure.save {
		t.Fatal("a note it is unsure of must be answered, not kept silently")
	}
}

func TestSmallRules(t *testing.T) {
	if !obviousNote("", 1) || !obviousNote(" https://a.b/c  https://d.e ", 0) || obviousNote("see https://a.b", 0) || obviousNote("", 0) {
		t.Fatal("obviousNote")
	}
	if !silentSoFar("<sa") || !silentSoFar(" <saved> ") || silentSoFar("<b>bold</b>") || silentSoFar("Sure") {
		t.Fatal("silentSoFar")
	}
	at := time.Date(2026, 10, 31, 0, 0, 0, 0, time.UTC)
	if got := rememberLine("  I   like\ntea @aseman ", at); got != "- I like tea (2026-10-31)\n" {
		t.Fatalf("rememberLine %q", got)
	}
	if rememberLine("my PIN is 1234", at) != "" || rememberLine("api key sk-123", at) != "" {
		t.Fatal("a secret must not be remembered into every prompt")
	}
	brief := brainBrief("", []brainRoomView{{brainRoom: brainRoom{Name: "Zed"}}, {brainRoom: brainRoom{Name: "Alpha"}}})
	if brief != "Their rooms you may read: Alpha, Zed." {
		t.Fatalf("brief %q", brief)
	}
}

// A note spoken in a live voice chat is always answered, and without asking the decision model: a conversation
// that waited on a decision, or kept a remark without replying, would not be a conversation.
func TestASpokenNoteIsAlwaysAnsweredWithoutADecision(t *testing.T) {
	f := newBrainFixture(t)
	f.plan = brainPlan{decided: true, save: true} // as a typed note this would be kept without a reply
	asked := 0
	f.s.decideFn = func(context.Context, string) brainPlan {
		asked++
		return f.plan
	}
	f.must("dm_send", f.alice, map[string]any{"to": f.alice.ID.String(), "body": "the café opens on friday", "voice": true})
	out := f.settled()
	if agentAnswers(out) != 1 || asked != 0 {
		t.Fatalf("answers %d, decision asked %d times", agentAnswers(out), asked)
	}
	f.mu.Lock()
	brief := f.briefs[len(f.briefs)-1]
	f.mu.Unlock()
	if !strings.Contains(brief, "spoken conversation") {
		t.Fatalf("the answer was not told it is spoken: %q", brief)
	}
}

func TestSpokenRequestsToDoThingsGetTools(t *testing.T) {
	for body, want := range map[string]bool{
		"create a room for my café": true, "remind me to call mum at six": true, "send a message to Sam saying I'm late": true,
		"what's my balance": true, "how are you today": false, "what is a good name for a café": false, "tell me about the make of this camera": false,
	} {
		if voiceWantsAction(body) != want {
			t.Errorf("%q: want tools %v", body, want)
		}
	}
}
