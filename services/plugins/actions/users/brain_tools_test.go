package users

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// actFixture is the brain harness whose answer model calls the tools the test
// gives it, and whose actions are recorded instead of run.
type actFixture struct {
	*brainFixture
	calls    [][2]string // tool calls the model makes: name, args
	acted    []string    // node actions run as the person: namespace.action
	actedMu  sync.Mutex
	answered int
}

func newActFixture(t *testing.T, reply string, calls ...[2]string) *actFixture {
	f := &actFixture{brainFixture: newBrainFixture(t), calls: calls}
	f.plan = brainPlan{decided: true, act: true}
	f.s.actFn = func(_ context.Context, _ identity.ID, _ string, _ []map[string]string, run func(name, args string) string) (string, error) {
		f.actedMu.Lock()
		f.answered++
		f.actedMu.Unlock()
		for _, c := range f.calls {
			run(c[0], c[1])
		}
		return reply, nil
	}
	f.s.dispatchFn = func(_ context.Context, _ identity.ID, namespace, action string, body any) (json.RawMessage, error) {
		f.actedMu.Lock()
		f.acted = append(f.acted, namespace+"."+action)
		f.actedMu.Unlock()
		return json.RawMessage(`{"id":"00000000000000010000000000000b01","space_id":"00000000000000010000000000000b01","name":"Launch"}`), nil
	}
	return f
}

func (f *actFixture) actions() []string {
	f.actedMu.Lock()
	defer f.actedMu.Unlock()
	return append([]string(nil), f.acted...)
}

// lastAnswer is Aseman's newest answer in the notes.
func (f *actFixture) lastAnswer() map[string]any {
	out := f.settled()
	var last map[string]any
	for _, m := range out["messages"].([]any) {
		if mm := m.(map[string]any); mm["agent_id"] != nil {
			last = mm
		}
	}
	return last
}

func TestAChangeIsOnlyProposedUntilConfirmed(t *testing.T) {
	f := newActFixture(t, "I'll create the room Launch. Confirm?", [2]string{"create_room", `{"name":"Launch","description":"the launch"}`})
	f.note("make me a room for the launch")
	answer := f.lastAnswer()
	if len(f.actions()) != 0 {
		t.Fatalf("it acted before the person said yes: %v", f.actions())
	}
	proposal, _ := answer["proposal"].(map[string]any)
	if proposal == nil || proposal["status"] != "pending" || proposal["steps"].([]any)[0] != "Create the room “Launch”" {
		t.Fatalf("proposal %v", answer["proposal"])
	}
	out := f.must("brain_confirm", f.alice, map[string]any{"message": answer["id"], "approve": true})
	if out["status"] != "done" || !strings.Contains(out["result"].(string), "✓ Create the room “Launch”") {
		t.Fatalf("confirm %v", out)
	}
	if acts := f.actions(); len(acts) != 1 || acts[0] != "spaces.space_create" {
		t.Fatalf("acted %v", acts)
	}
	if _, err := f.call("brain_confirm", f.alice, map[string]any{"message": answer["id"], "approve": true}); err == nil {
		t.Fatal("a proposal was carried out twice")
	}
}

func TestReplyingYesCarriesItOutWithoutAskingTheModel(t *testing.T) {
	f := newActFixture(t, "Shall I message them?", [2]string{"message_person", `{"person":"00000000000000010000000000000002","text":"see you at 6"}`})
	f.note("tell bob see you at 6")
	f.lastAnswer()
	f.note("yes")
	answer := f.lastAnswer()
	if acts := f.actions(); len(acts) != 1 || acts[0] != "users.dm_send" {
		t.Fatalf("acted %v", acts)
	}
	if !strings.HasPrefix(answer["body"].(string), "✓ Send") || f.answered != 1 {
		t.Fatalf("answer %q after %d model answers", answer["body"], f.answered)
	}
}

func TestReplyingNoCancelsIt(t *testing.T) {
	f := newActFixture(t, "Create it?", [2]string{"create_room", `{"name":"X"}`})
	f.note("new room X")
	proposalMsg := f.lastAnswer()
	f.note("no")
	if answer := f.lastAnswer(); answer["body"] != "Cancelled." || len(f.actions()) != 0 {
		t.Fatalf("answer %v, acted %v", answer["body"], f.actions())
	}
	for _, m := range f.settled()["messages"].([]any) {
		if mm := m.(map[string]any); mm["id"] == proposalMsg["id"] && mm["proposal"].(map[string]any)["status"] != "cancelled" {
			t.Fatalf("proposal %v", mm["proposal"])
		}
	}
}

func TestOnlyThePersonCanConfirmTheirProposal(t *testing.T) {
	f := newActFixture(t, "Create it?", [2]string{"create_room", `{"name":"X"}`})
	f.note("new room X")
	answer := f.lastAnswer()
	if _, err := f.call("brain_confirm", f.bob, map[string]any{"message": answer["id"], "approve": true}); err == nil {
		t.Fatal("someone else confirmed it")
	}
	if len(f.actions()) != 0 {
		t.Fatal("it acted")
	}
}

func TestARemindersIsSetAtOnceAndDeliveredWhenDue(t *testing.T) {
	at := time.Now().Add(time.Hour).UTC().Format(time.RFC3339)
	f := newActFixture(t, "I'll remind you.", [2]string{"remind_me", `{"at":"` + at + `","text":"call mum"}`})
	f.note("remind me in an hour to call mum")
	answer := f.lastAnswer()
	if answer["proposal"] != nil {
		t.Fatal("a reminder is the person's own: nothing to confirm")
	}
	rs, err := f.s.reminders(context.Background(), f.alice.ID)
	if err != nil || len(rs) != 1 || rs[0].Text != "call mum" {
		t.Fatalf("reminders %v %v", rs, err)
	}
	f.s.deliverReminders(context.Background(), time.Now().Add(2*time.Hour).UTC())
	if got := f.lastAnswer(); got["body"] != "⏰ call mum" {
		t.Fatalf("delivered %v", got["body"])
	}
	if rs, _ := f.s.reminders(context.Background(), f.alice.ID); len(rs) != 0 {
		t.Fatal("a delivered reminder is still waiting")
	}
}

func TestToolsAnswerTheModelWithErrorsItCanReadOut(t *testing.T) {
	f := newActFixture(t, "")
	var proposed []brainStep
	run := f.s.brainRun(context.Background(), f.alice.ID, &proposed, map[string]string{})
	if got := run("delete_everything", "{}"); !strings.HasPrefix(got, "error: no tool") {
		t.Fatal(got)
	}
	if got := run("room_activity", `{"room":"nope"}`); !strings.HasPrefix(got, "error:") {
		t.Fatal(got)
	}
	if got := run("create_room", "not json"); !strings.HasPrefix(got, "error:") {
		t.Fatal(got)
	}
	for i := 0; i < 6; i++ {
		run("create_room", `{"name":"r"}`)
	}
	if len(proposed) != 5 {
		t.Fatalf("%d proposed at once", len(proposed))
	}
}

func TestBrainToolsCoverAccountSurfaces(t *testing.T) {
	want := map[string]bool{
		"list_rooms": true, "list_chats": true, "list_participants": true,
		"list_agents": true, "list_apps": true, "recruit_agent": true,
		"hire_agent": true, "message_room": true, "message_person": true,
		"invite_to_room": true, "create_room": true, "ask_room": true,
		"work_on_it": true, "wallet_balance": true, "find_people": true,
		"call_action": true,
	}
	for _, tool := range brainTools() {
		delete(want, tool.Name)
	}
	if len(want) != 0 {
		t.Fatalf("missing tools: %v", want)
	}
}

func TestCallActionRefusesAdminSurfaces(t *testing.T) {
	if !deniedBrainAction("admin", "health") || !deniedBrainAction("spaces", "agent_engine_set") {
		t.Fatal("admin surfaces must be denied")
	}
	if deniedBrainAction("spaces", "thread_list") || deniedBrainAction("posts", "post_feed") {
		t.Fatal("normal account actions must be allowed")
	}
}

func TestYesAndNoAreRecognized(t *testing.T) {
	for _, y := range []string{"yes", "Yes!", "ok", "do it", "go ahead.", "بله"} {
		if !sayYes.MatchString(y) {
			t.Errorf("%q is a yes", y)
		}
	}
	for _, n := range []string{"no", "Cancel", "نه"} {
		if !sayNo.MatchString(n) {
			t.Errorf("%q is a no", n)
		}
	}
	if sayYes.MatchString("yes but make it called Beta") {
		t.Error("a yes with more to say goes to the model")
	}
}

func TestOutOfCreditsOffersAWayBackAndPicksTheNoteUpAfter(t *testing.T) {
	f := newActFixture(t, "Here is your plan.")
	broke := true
	answerFn := f.s.actFn
	f.s.actFn = func(ctx context.Context, person identity.ID, brief string, turns []map[string]string, run func(name, args string) string) (string, error) {
		f.actedMu.Lock()
		poor := broke
		f.actedMu.Unlock()
		if poor {
			return "", errs.New(errs.CodeFinance, "insufficient funds")
		}
		return answerFn(ctx, person, brief, turns, run)
	}
	f.s.fundsFn = func(context.Context, identity.ID) error {
		f.actedMu.Lock()
		defer f.actedMu.Unlock()
		if broke {
			return errs.New(errs.CodeFinance, "insufficient funds")
		}
		return nil
	}
	note := f.note("plan my week")
	card := f.lastAnswer()
	if card["brain"] != "credits" || card["reply_to"] != note["id"] || strings.Contains(card["body"].(string), "wrong") {
		t.Fatalf("card %v", card)
	}
	// Still no credits: nothing happens, and the person is told.
	if _, err := f.call("brain_retry", f.alice, map[string]any{"message": card["id"]}); err == nil {
		t.Fatal("retried with no credits")
	}
	f.actedMu.Lock()
	broke = false
	f.actedMu.Unlock()
	f.must("brain_retry", f.alice, map[string]any{"message": card["id"]})
	answer := f.lastAnswer()
	if answer["body"] != "Here is your plan." || answer["reply_to"] != note["id"] {
		t.Fatalf("answer %v", answer)
	}
	for _, m := range f.settled()["messages"].([]any) {
		if m.(map[string]any)["id"] == card["id"] {
			t.Fatal("the credits card is still in the chat")
		}
	}
	if _, err := f.call("brain_retry", f.bob, map[string]any{"message": card["id"]}); err == nil {
		t.Fatal("someone else retried it")
	}
}

// A tool with nothing required must not send "required": null: providers answer such a request with a 400.
func TestBrainToolSchemasHaveNoNullRequired(t *testing.T) {
	for _, tool := range brainTools() {
		raw, err := json.Marshal(tool.Parameters)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(raw), `"required":null`) {
			t.Errorf("%s: schema sends null for required: %s", tool.Name, raw)
		}
	}
}

// What Aseman made or shows comes as cards under its answer: a created room is one to tap, a chart is drawn.
func TestCardsAreStoredWithTheAnswer(t *testing.T) {
	f := newActFixture(t, "Here you go.", [2]string{"show_chart", `{"title":"Spend by room","unit":"credits","points":[{"label":"Launch","value":12},{"label":"Café","value":30}]}`}, [2]string{"show_chart", `{"title":"bad","points":[{"label":"only","value":1}]}`})
	f.note("chart my spend")
	proposal, _ := f.lastAnswer()["proposal"].(map[string]any)
	if proposal == nil || proposal["status"] != "shown" {
		t.Fatalf("proposal %v", proposal)
	}
	cards := proposal["cards"].([]any)
	chart := cards[0].(map[string]any)
	if len(cards) != 1 || chart["type"] != "chart" || chart["title"] != "Spend by room" || len(chart["points"].([]any)) != 2 {
		t.Fatalf("cards %v", cards)
	}

	g := newActFixture(t, "I'll create it. Confirm?", [2]string{"create_room", `{"name":"Launch"}`})
	g.note("make a room")
	answer := g.lastAnswer()
	g.must("brain_confirm", g.alice, map[string]any{"message": answer["id"], "approve": true})
	done, _ := g.lastAnswer()["proposal"].(map[string]any)
	made := done["cards"].([]any)
	room := made[0].(map[string]any)
	if room["type"] != "room" || room["id"] != "00000000000000010000000000000b01" || room["title"] != "Launch" {
		t.Fatalf("room card %v", made)
	}
}

// Work that needs a computer is proposed, confirmed once, handed to the person's workspace without waiting, and written up in
// their notes (with a card that opens the workspace) when the team has finished.
func TestWorkNeedingAComputerIsHandedToTheWorkspaceAndWrittenUpWhenDone(t *testing.T) {
	f := newActFixture(t, "I'll do that in your workspace. Confirm?", [2]string{"work_on_it", `{"request":"Find how many founders bowora.com has and list them with their roles"}`})
	// The workspace is among their rooms, under a new name: the card shows the name it has now.
	f.rooms = []brainRoom{{ID: "00000000000000010000000000000c01", Name: "My workspace", Owner: true}}
	var started []string
	finished := false
	f.s.workFn = func(_ context.Context, _ identity.ID, request string) (workStart, error) {
		started = append(started, request)
		return workStart{SpaceID: "00000000000000010000000000000c01", Name: "shayan's Home", TurnID: "00000000000000010000000000000d01"}, nil
	}
	f.s.turnFn = func(context.Context, identity.ID, string) (turnResult, error) {
		if !finished {
			return turnResult{Status: "running"}, nil
		}
		return turnResult{Finished: true, Status: "done", Reply: "Bowora has two founders: Sam Lee (CEO) and Ana Ruiz (CTO)."}, nil
	}
	f.note("research how many founders bowora has")
	answer := f.lastAnswer()
	proposal, _ := answer["proposal"].(map[string]any)
	if proposal == nil || proposal["status"] != "pending" || !strings.HasPrefix(proposal["steps"].([]any)[0].(string), "Work on this in your workspace") {
		t.Fatalf("proposal %v", answer["proposal"])
	}
	if len(started) != 0 {
		t.Fatal("work began before the person confirmed")
	}
	f.must("brain_confirm", f.alice, map[string]any{"message": answer["id"], "approve": true})
	if len(started) != 1 || !strings.Contains(started[0], "bowora.com") {
		t.Fatalf("started %v", started)
	}
	// Still running: nothing is written yet.
	f.s.deliverJobs(f.ctx, time.Now())
	before := agentAnswers(f.settled())
	finished = true
	f.s.deliverJobs(f.ctx, time.Now())
	out := f.settled()
	if agentAnswers(out) != before+1 {
		t.Fatalf("the finished work was not written up: %d answers before, %d after", before, agentAnswers(out))
	}
	last := f.lastAnswer()
	if !strings.Contains(last["body"].(string), "Sam Lee") {
		t.Fatalf("body %q", last["body"])
	}
	cards := last["proposal"].(map[string]any)["cards"].([]any)
	card := cards[0].(map[string]any)
	if card["type"] != "room" || card["id"] != "00000000000000010000000000000c01" || card["title"] != "My workspace" {
		t.Fatalf("card %v", cards)
	}
	// Told once.
	f.s.deliverJobs(f.ctx, time.Now())
	if agentAnswers(f.settled()) != before+1 {
		t.Fatal("the same work was written up twice")
	}
}

// Aseman knows about the work it has handed on (so it can say it will write when it is done), the admin's AI log shows
// the finished work, and a workspace that is gone is said to be gone at once.
func TestJobsAreKnownToAsemanLoggedAndAGoneWorkspaceIsSaid(t *testing.T) {
	f := newActFixture(t, "On it.", [2]string{"work_on_it", `{"request":"Screenshot bowora.com/about"}`})
	f.rooms = []brainRoom{{ID: "00000000000000010000000000000c01", Name: "Home", Owner: true}}
	f.s.workFn = func(context.Context, identity.ID, string) (workStart, error) {
		return workStart{SpaceID: "00000000000000010000000000000c01", Name: "Home", TurnID: "00000000000000010000000000000d01"}, nil
	}
	f.s.turnFn = func(context.Context, identity.ID, string) (turnResult, error) {
		return turnResult{Status: "running"}, nil
	}
	f.note("take a screenshot of bowora.com/about")
	answer := f.lastAnswer()
	f.must("brain_confirm", f.alice, map[string]any{"message": answer["id"], "approve": true})

	brief := f.s.jobsBrief(f.ctx, f.alice.ID)
	if !strings.Contains(brief, "<your_work>") || !strings.Contains(brief, "Screenshot bowora.com/about") || !strings.Contains(brief, "write the result in these notes by yourself") {
		t.Fatalf("brief: %q", brief)
	}

	// The room is gone: the next look says so, it does not wait.
	f.s.turnFn = func(context.Context, identity.ID, string) (turnResult, error) {
		return turnResult{}, errs.NotFound("workspace")
	}
	f.s.deliverJobs(f.ctx, time.Now())
	out := f.settled()
	last := f.lastAnswer()
	if !strings.Contains(last["body"].(string), "gone") || agentAnswers(out) != 2 {
		t.Fatalf("body %q", last["body"])
	}
	if strings.Contains(f.s.jobsBrief(f.ctx, f.alice.ID), "still running") {
		t.Fatal("finished work is still described as running")
	}

	// The AI log has the confirmation and the end of the work.
	var logs []aiLog
	if err := f.s.R.List(f.ctx, "ai_logs", database.Filter{}, &logs); err != nil {
		t.Fatal(err)
	}
	plans := map[string]string{}
	for _, l := range logs {
		plans[l.Plan] = l.Status
	}
	if plans["confirm"] != aiAction || plans["work"] != aiError {
		t.Fatalf("plans logged: %v", plans)
	}
}
