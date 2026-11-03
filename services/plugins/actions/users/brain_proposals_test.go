package users

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// actFixture is the brain harness whose acting answer (on the agent runtime
// in production) is a fixed reply.
type actFixture struct {
	*brainFixture
	actedMu  sync.Mutex
	answered int
}

func newActFixture(t *testing.T, reply string) *actFixture {
	f := &actFixture{brainFixture: newBrainFixture(t)}
	f.plan = brainPlan{decided: true, act: true}
	f.s.actFn = func(context.Context, identity.ID, string, []map[string]string) (string, error) {
		f.actedMu.Lock()
		f.answered++
		f.actedMu.Unlock()
		return reply, nil
	}
	return f
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

// legacyProposal gives Aseman's newest answer a proposal as an earlier
// version stored them.
func (f *actFixture) legacyProposal(t *testing.T) map[string]any {
	t.Helper()
	answer := f.lastAnswer()
	id, err := identity.Parse(answer["id"].(string))
	if err != nil {
		t.Fatal(err)
	}
	p := &brainProposal{Status: proposalPending, Steps: []brainStep{{Tool: "create_room", Args: map[string]any{"name": "X"}, Summary: "Create the room “X”"}}}
	if err := f.s.setProposal(f.ctx, id, p); err != nil {
		t.Fatal(err)
	}
	return answer
}

// An answer acts on the agent runtime: it proposes nothing of its own.
func TestAnActingAnswerStoresNoProposal(t *testing.T) {
	f := newActFixture(t, "Done: the room Launch is ready.")
	f.note("make me a room for the launch")
	answer := f.lastAnswer()
	if answer["body"] != "Done: the room Launch is ready." || answer["proposal"] != nil || f.answered != 1 {
		t.Fatalf("answer %v after %d answers", answer, f.answered)
	}
}

// A proposal an earlier version stored can be cancelled; a yes says to ask again, and nothing runs.
func TestAnOlderProposalIsCancelledOrAskedAgain(t *testing.T) {
	f := newActFixture(t, "Create it?")
	f.note("new room X")
	answer := f.legacyProposal(t)
	if _, err := f.call("brain_confirm", f.bob, map[string]any{"message": answer["id"], "approve": true}); err == nil {
		t.Fatal("someone else answered it")
	}
	out := f.must("brain_confirm", f.alice, map[string]any{"message": answer["id"], "approve": true})
	if out["status"] != proposalFailed || !strings.Contains(out["result"].(string), "ask again") {
		t.Fatalf("confirm %v", out)
	}
	if _, err := f.call("brain_confirm", f.alice, map[string]any{"message": answer["id"], "approve": true}); err == nil {
		t.Fatal("answered twice")
	}

	g := newActFixture(t, "Create it?")
	g.note("new room X")
	g.legacyProposal(t)
	g.note("no")
	if last := g.lastAnswer(); last["body"] != "Cancelled." || g.answered != 1 {
		t.Fatalf("answer %v after %d answers", last["body"], g.answered)
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
	f.s.actFn = func(ctx context.Context, person identity.ID, brief string, turns []map[string]string) (string, error) {
		f.actedMu.Lock()
		poor := broke
		f.actedMu.Unlock()
		if poor {
			return "", errs.New(errs.CodeFinance, "insufficient funds")
		}
		return answerFn(ctx, person, brief, turns)
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

// handOff is work an earlier answer handed to the person's workspace.
func (f *actFixture) handOff(t *testing.T, request string) {
	t.Helper()
	f.note(request)
	note := f.lastAnswer()["reply_to"].(string)
	start := workStart{SpaceID: "00000000000000010000000000000c01", Name: "shayan's Home", TurnID: "00000000000000010000000000000d01"}
	if err := f.s.addJob(f.ctx, f.alice.ID, start, request, note); err != nil {
		t.Fatal(err)
	}
}

// Work handed to the person's workspace is written up in their notes (with a card that opens the workspace) when the
// team has finished, once.
func TestHandedWorkIsWrittenUpWhenDone(t *testing.T) {
	f := newActFixture(t, "I'll do that in your workspace.")
	// The workspace is among their rooms, under a new name: the card shows the name it has now.
	f.rooms = []brainRoom{{ID: "00000000000000010000000000000c01", Name: "My workspace", Owner: true}}
	finished := false
	f.s.turnFn = func(context.Context, identity.ID, string) (turnResult, error) {
		if !finished {
			return turnResult{Status: "running"}, nil
		}
		return turnResult{Finished: true, Status: "done", Reply: "Bowora has two founders: Sam Lee (CEO) and Ana Ruiz (CTO)."}, nil
	}
	f.handOff(t, "research how many founders bowora has")
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

// Aseman knows about the work handed on (so it can say it will write when it is done), the admin's AI log shows the
// finished work, and a workspace that is gone is said to be gone at once.
func TestJobsAreKnownToAsemanLoggedAndAGoneWorkspaceIsSaid(t *testing.T) {
	f := newActFixture(t, "On it.")
	f.rooms = []brainRoom{{ID: "00000000000000010000000000000c01", Name: "Home", Owner: true}}
	f.s.turnFn = func(context.Context, identity.ID, string) (turnResult, error) {
		return turnResult{Status: "running"}, nil
	}
	f.handOff(t, "Screenshot bowora.com/about")

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

	var logs []aiLog
	if err := f.s.R.List(f.ctx, "ai_logs", database.Filter{}, &logs); err != nil {
		t.Fatal(err)
	}
	plans := map[string]string{}
	for _, l := range logs {
		plans[l.Plan] = l.Status
	}
	if plans["work"] != aiError {
		t.Fatalf("plans logged: %v", plans)
	}
}
