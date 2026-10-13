package spaces

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/jsonpatch"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
	"github.com/tradera/tradera/plugins/adapters/base"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
	vmm "github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// fakeAgentRuntime stands in for the deep agents runtime and records the turns
// the space routes to it.
type fakeAgentRuntime struct {
	vmm.VMM
	base.Base
	mu       sync.Mutex
	prompts  []vmm.AgentTurn
	observed []vmm.AgentTurn
	replies  []vmm.AgentTurn
	waiting  map[string]bool // vm ids with a pending question
	waitRoom string          // the room those questions were asked in
	// started counts turns that began; gate (when set) holds every turn until
	// it is closed, so tests can see turns running at the same time.
	started chan string
	gate    chan struct{}
	fail    error
}

func newFakeAgentRuntime() *fakeAgentRuntime {
	return &fakeAgentRuntime{Base: base.Base{Name: "deepagents", Category: api.CategoryVMM}, waiting: map[string]bool{}}
}

func (f *fakeAgentRuntime) Name() string                                  { return "deepagents" }
func (f *fakeAgentRuntime) Init(context.Context, *api.Dependencies) error { return nil }
func (f *fakeAgentRuntime) Start(context.Context) error                   { return nil }
func (f *fakeAgentRuntime) Stop(context.Context) error                    { return nil }
func (f *fakeAgentRuntime) SupportedTypes() []vmm.Type                    { return []vmm.Type{vmm.TypeDeepAgents} }

func (f *fakeAgentRuntime) Prompt(ctx context.Context, vmID string, turn vmm.AgentTurn) (string, error) {
	f.mu.Lock()
	f.prompts = append(f.prompts, turn)
	started, gate, fail := f.started, f.gate, f.fail
	f.mu.Unlock()
	if started != nil {
		started <- turn.Agent.Name
	}
	if gate != nil {
		<-gate
	}
	if fail != nil {
		return "partial work by " + turn.Agent.Name, fail
	}
	if p := vmm.ExecutionFrom(ctx); p.AgentID != turn.Agent.BotID || p.RoomID != turn.RoomID || vmm.RoomFrom(ctx) != turn.RoomID {
		return "", nil
	}
	return "done by " + turn.Agent.Name, nil
}

func (f *fakeAgentRuntime) Observe(_ context.Context, _ string, turn vmm.AgentTurn) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.observed = append(f.observed, turn)
	return nil
}

func (f *fakeAgentRuntime) Reply(_ context.Context, vmID string, turn vmm.AgentTurn) (bool, string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.waiting[vmID] {
		return false, "", nil
	}
	f.replies = append(f.replies, turn)
	delete(f.waiting, vmID)
	return true, "thanks, continuing with " + turn.Message, nil
}

func (f *fakeAgentRuntime) Questions(_ context.Context, vmID, spaceID string) ([]vmm.AgentQuestion, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.waiting[vmID] {
		return nil, nil
	}
	return []vmm.AgentQuestion{{ID: "q-" + vmID, SpaceID: spaceID, RoomID: f.waitRoom, Question: "Which color?", Kind: "question", AskedAt: "2026-01-01T00:00:00Z"}}, nil
}

// addSandbox gives the space a running sandbox computer (vm "sbx-vm").
func addSandbox(t *testing.T, s *Service, ctx context.Context, spaceID identity.ID) {
	t.Helper()
	sandbox := addAgent(t, s, ctx, spaceID, "sbx", "sbx-vm")
	sandbox.Kind, sandbox.VMType, sandbox.ImageRef = bot.KindTool, bot.VMTypeContainer, defaultSandboxImage
	if err := s.R.Update(ctx, "bots", sandbox.ID, sandbox); err != nil {
		t.Fatal(err)
	}
	if err := s.M.Patch(ctx, spaceID, jsonpatch.Patch{{Op: "set", Path: "sandbox/bot_id", Value: sandbox.ID.String()}}); err != nil {
		t.Fatal(err)
	}
}

func bootRuntime(t *testing.T, s *Service, ctx context.Context) *fakeAgentRuntime {
	t.Helper()
	rt := newFakeAgentRuntime()
	if err := s.K.(*kernel.Kernel).Register(rt); err != nil {
		t.Fatal(err)
	}
	if err := s.K.(*kernel.Kernel).Boot(ctx, []string{"deepagents"}); err != nil {
		t.Fatal(err)
	}
	return rt
}

// sandboxBots runs the sandbox lifecycle without a container provider.
type sandboxBots struct{ BotPort }

func (b sandboxBots) EnsureVM(context.Context, *bot.Bot) error { return nil }
func (b sandboxBots) Lifecycle(ctx context.Context, id identity.ID, op string) (*bot.Bot, error) {
	rec, err := b.GetBot(ctx, id)
	if err == nil {
		rec.Status = bot.StatusRunning
	}
	return rec, err
}

func addAgent(t *testing.T, s *Service, ctx context.Context, spaceID identity.ID, name, vmID string) *bot.Bot {
	t.Helper()
	now := time.Now().UTC()
	accID, _ := identity.New(s.K.NodeID())
	if err := s.R.CreateID(ctx, "accounts", accID, &account.Account{Entity: entity.Entity{ID: accID, CreatedAt: now},
		Kind: account.KindBot, Handle: name, Status: account.StatusActive, MetadataID: accID}); err != nil {
		t.Fatal(err)
	}
	botID, _ := identity.New(s.K.NodeID())
	rec := &bot.Bot{Entity: entity.Entity{ID: botID, CreatedAt: now}, OwnerID: accID, AccountID: accID, Name: name,
		Kind: bot.KindAgent, VMType: bot.VMTypeDeepAgents, Status: bot.StatusRunning, VMID: vmID}
	if err := s.R.CreateID(ctx, "bots", botID, rec); err != nil {
		t.Fatal(err)
	}
	memID, _ := identity.New(s.K.NodeID())
	if err := s.R.CreateID(ctx, "memberships", memID, &membership.Membership{Entity: entity.Entity{ID: memID, CreatedAt: now},
		SpaceID: spaceID, MemberID: accID, Role: membership.RoleBot, JoinedAt: now}); err != nil {
		t.Fatal(err)
	}
	return rec
}

func TestRoomMessagesReachAgentsThroughSpaceMessaging(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "launch team", "")
	if err != nil {
		t.Fatal(err)
	}
	room, err := s.generalRoom(ctx, sp.ID)
	if err != nil {
		t.Fatal(err)
	}
	s.Bots = sandboxBots{mentionBots{BotPort: s.Bots}}
	rt := bootRuntime(t, s, ctx)
	helper := addAgent(t, s, ctx, sp.ID, "helper", "g-helper")
	observer := addAgent(t, s, ctx, sp.ID, "observer", "g-observer")
	addSandbox(t, s, ctx, sp.ID)

	msgID, _ := identity.New(s.K.NodeID())
	msg := &message.Message{Entity: entity.Entity{ID: msgID, CreatedAt: time.Now()}, SpaceID: sp.ID, RoomID: room.ID, SenderID: owner, Body: "@helper ship the landing page"}
	msg.SetMentions([]string{helper.ID.String()})
	replies, err := s.DeliverMentions(ctx, sp.ID, room.ID, msg)
	if err != nil {
		t.Fatal(err)
	}
	if len(replies) != 1 || replies[0].BotID != helper.ID.String() || replies[0].Reply != "done by helper" || replies[0].MessageID == "" {
		t.Fatalf("unexpected replies %+v", replies)
	}
	// Every other agent (the observer and the built-in tradera lead) records
	// the message for its next turn.
	observedBy := map[string]bool{}
	for _, o := range rt.observed {
		observedBy[o.Agent.Name] = true
	}
	if len(rt.prompts) != 1 || !observedBy["observer"] || !observedBy["tradera"] || observedBy["helper"] {
		t.Fatalf("prompts=%d observed=%v", len(rt.prompts), observedBy)
	}
	turn := rt.prompts[0]
	if turn.Sandbox != (vmm.SandboxRef{Type: vmm.TypeContainer, VMID: "sbx-vm"}) || turn.RoomID != room.ID.String() || turn.MessageID != msgID.String() {
		t.Fatalf("turn not bound to the space sandbox/room/message: %+v", turn)
	}
	for _, want := range []string{`Space: "launch team"`, "observer (bot " + observer.ID.String() + ")", "Other agents"} {
		if !strings.Contains(turn.Context, want) {
			t.Fatalf("context missing %q:\n%s", want, turn.Context)
		}
	}
	var stored []message.Message
	if err := s.R.List(ctx, "messages", database.Filter{Equal: map[string]any{"room_id": room.ID.String(), "sender_id": helper.AccountID.String()}}, &stored); err != nil || len(stored) != 1 {
		t.Fatalf("agent reply not posted to the room: %v %v", stored, err)
	}
	if stored[0].ReplyTo != msgID.String() {
		t.Fatalf("reply not threaded to its request: reply_to=%q", stored[0].ReplyTo)
	}

	// An agent waiting on its question receives a person's next room message
	// as the answer, resumes, and its words are stored as its reply. Another
	// agent's message is never taken as a person's answer.
	rt.waiting["g-observer"] = true
	rt.waitRoom = room.ID.String()
	qs, err := s.AgentQuestions(ctx, sp.ID)
	if err != nil || len(qs) != 1 || qs[0].BotID != observer.ID.String() || qs[0].Agent != "observer" {
		t.Fatalf("open questions = %+v, %v", qs, err)
	}
	fromHelper := &message.Message{Entity: entity.Entity{CreatedAt: time.Now()}, SpaceID: sp.ID, RoomID: room.ID, SenderID: helper.AccountID, Body: "progress update"}
	if _, err := s.DeliverMentions(ctx, sp.ID, room.ID, fromHelper); err != nil {
		t.Fatal(err)
	}
	answerID, _ := identity.New(s.K.NodeID())
	answer := &message.Message{Entity: entity.Entity{ID: answerID, CreatedAt: time.Now()}, SpaceID: sp.ID, RoomID: room.ID, SenderID: owner, Body: "use blue"}
	replies, err = s.DeliverMentions(ctx, sp.ID, room.ID, answer)
	if err != nil {
		t.Fatal(err)
	}
	if len(rt.replies) != 1 || rt.replies[0].Message != "use blue" {
		t.Fatalf("answer not routed to the waiting agent: %+v", rt.replies)
	}
	if len(replies) != 1 || replies[0].Reply != "thanks, continuing with use blue" {
		t.Fatalf("resumed agent's words not stored: %+v", replies)
	}
	for _, o := range rt.observed {
		if o.Agent.BotID == helper.ID.String() && o.SenderID == helper.AccountID.String() {
			t.Fatal("agent received its own message")
		}
	}
}

func TestMentionedAgentsWorkInParallel(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "parallel", "")
	if err != nil {
		t.Fatal(err)
	}
	addSandbox(t, s, ctx, sp.ID)
	room, _ := s.generalRoom(ctx, sp.ID)
	s.Bots = sandboxBots{mentionBots{BotPort: s.Bots}}
	rt := bootRuntime(t, s, ctx)
	rt.started, rt.gate = make(chan string, 4), make(chan struct{})
	a := addAgent(t, s, ctx, sp.ID, "alpha", "g-a")
	b := addAgent(t, s, ctx, sp.ID, "beta", "g-b")
	msg := &message.Message{Entity: entity.Entity{CreatedAt: time.Now()}, SpaceID: sp.ID, RoomID: room.ID, SenderID: owner, Body: "both of you"}
	msg.SetMentions([]string{a.ID.String(), b.ID.String()})
	done := make(chan []MentionReply, 1)
	go func() {
		replies, _ := s.DeliverMentions(ctx, sp.ID, room.ID, msg)
		done <- replies
	}()
	seen := map[string]bool{}
	for range 2 {
		select {
		case name := <-rt.started:
			seen[name] = true
		case <-time.After(5 * time.Second):
			t.Fatalf("agents ran one after another; started=%v", seen)
		}
	}
	close(rt.gate)
	if replies := <-done; len(replies) != 2 || !seen["alpha"] || !seen["beta"] {
		t.Fatalf("replies=%+v seen=%v", replies, seen)
	}
}

func TestAgentChainsAreBoundedAndTargetsResolve(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "chain test", "")
	if err != nil {
		t.Fatal(err)
	}
	addSandbox(t, s, ctx, sp.ID)
	room, _ := s.generalRoom(ctx, sp.ID)
	s.Bots = sandboxBots{mentionBots{BotPort: s.Bots}}
	rt := bootRuntime(t, s, ctx)
	a := addAgent(t, s, ctx, sp.ID, "alpha", "g-a")
	b := addAgent(t, s, ctx, sp.ID, "Beta", "g-b")
	if got, err := s.findAgent(ctx, sp.ID, "@beta"); err != nil || got.ID != b.ID {
		t.Fatalf("name lookup: %v %v", got, err)
	}
	deep := ctx
	for range vmm.MaxAgentAskDepth {
		deep = vmm.WithAgentAsk(deep)
	}
	msg := &message.Message{Entity: entity.Entity{CreatedAt: time.Now()}, SpaceID: sp.ID, RoomID: room.ID, SenderID: a.AccountID, Body: "@Beta take this"}
	msg.SetMentions([]string{b.ID.String()})
	if _, err := s.DeliverMentions(deep, sp.ID, room.ID, msg); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("unbounded agent chain accepted: %v", err)
	}
	if len(rt.prompts) != 0 {
		t.Fatal("agent started past the chain bound")
	}
	if _, err := s.DeliverMentions(ctx, sp.ID, room.ID, msg); err != nil || len(rt.prompts) != 1 {
		t.Fatalf("delegation from an agent not delivered: %v prompts=%d", err, len(rt.prompts))
	}
}

func TestFailedAgentTurnKeepsItsWorkAndError(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "failure", "")
	if err != nil {
		t.Fatal(err)
	}
	addSandbox(t, s, ctx, sp.ID)
	room, _ := s.generalRoom(ctx, sp.ID)
	s.Bots = sandboxBots{mentionBots{BotPort: s.Bots}}
	rt := bootRuntime(t, s, ctx)
	rt.fail = errs.New(errs.CodeBudgetExhausted, "model request exceeds remaining budget")
	a := addAgent(t, s, ctx, sp.ID, "alpha", "g-a")
	msg := &message.Message{Entity: entity.Entity{CreatedAt: time.Now()}, SpaceID: sp.ID, RoomID: room.ID, SenderID: owner, Body: "go"}
	msg.SetMentions([]string{a.ID.String()})
	replies, err := s.DeliverMentions(ctx, sp.ID, room.ID, msg)
	if errs.CodeOf(err) != errs.CodeBudgetExhausted {
		t.Fatalf("original failure hidden: %v", err)
	}
	if len(replies) != 1 || !strings.Contains(replies[0].Reply, "partial work by alpha") || !strings.Contains(replies[0].Reply, "alpha stopped") {
		t.Fatalf("partial work lost: %+v", replies)
	}
}

func TestDirectMessageRunsInTheSpaceTheAgentShares(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "project", "")
	if err != nil {
		t.Fatal(err)
	}
	s.Bots = sandboxBots{mentionBots{BotPort: s.Bots}}
	rt := bootRuntime(t, s, ctx)
	helper := addAgent(t, s, ctx, sp.ID, "helper", "g-helper")
	addSandbox(t, s, ctx, sp.ID)
	// The agent also being in the person's home space (an earlier DM puts it
	// there) does not pull the conversation out of the project.
	home, err := s.CreateHomeSpace(ctx, owner, "owner")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.AddBot(ctx, owner, home.ID, identity.ID{}, helper.AccountID); err != nil {
		t.Fatal(err)
	}
	reply, err := s.AskDirect(ctx, owner, helper.ID, "copy the file again", nil)
	if err != nil || reply != "done by helper" {
		t.Fatalf("AskDirect = %q, %v", reply, err)
	}
	if len(rt.prompts) != 1 || rt.prompts[0].SpaceID != sp.ID.String() || rt.prompts[0].Sandbox.VMID != "sbx-vm" {
		t.Fatalf("direct message did not run in the shared project: %+v", rt.prompts)
	}
}

func TestAgentTurnsAreBilledOnceToThePersonWhoStartedThem(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "billing", "")
	if err != nil {
		t.Fatal(err)
	}
	room, _ := s.generalRoom(ctx, sp.ID)
	log := &billLog{}
	s.Bots = sandboxBots{mentionBots{BotPort: s.Bots, billed: log}}
	rt := bootRuntime(t, s, ctx)
	helper := addAgent(t, s, ctx, sp.ID, "helper", "g-helper")
	addSandbox(t, s, ctx, sp.ID)

	send := func(body string, mentions ...string) {
		id, _ := identity.New(s.K.NodeID())
		m := &message.Message{Entity: entity.Entity{ID: id, CreatedAt: time.Now()}, SpaceID: sp.ID, RoomID: room.ID, SenderID: owner, Body: body}
		m.SetMentions(mentions)
		if _, err := s.DeliverMentions(ctx, sp.ID, room.ID, m); err != nil {
			t.Fatal(err)
		}
	}

	// A message that mentions the agent runs one turn, billed once to the sender.
	send("@helper do it", helper.ID.String())
	got := log.all()
	if len(got) != 1 || got[0].payer != owner || got[0].bot != helper.ID || got[0].seconds < 1 {
		t.Fatalf("a mention was billed %+v; want one turn billed to the person who sent it", got)
	}
	if len(rt.prompts) != 1 {
		t.Fatalf("prompts = %d", len(rt.prompts))
	}

	// A message the agent was not asked to answer is not a turn: not billed.
	send("just talking")
	if n := len(log.all()); n != 1 {
		t.Fatalf("an observed message was billed: %d bills", n)
	}

	// Asking the same agent while it waits on a question in another room is
	// still just a turn — and a message that answers nothing never bills.
	rt.waiting["g-helper"] = true
	rt.waitRoom = "some-other-room"
	send("@helper and again", helper.ID.String())
	if n := len(log.all()); n != 2 {
		t.Fatalf("want exactly one more bill for the new turn, have %d", n)
	}
	if len(rt.replies) != 0 {
		t.Fatalf("a message in another room answered the question: %+v", rt.replies)
	}
}

func TestDirectMessagesAreBilledToThePerson(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "dm billing", "")
	if err != nil {
		t.Fatal(err)
	}
	log := &billLog{}
	s.Bots = sandboxBots{mentionBots{BotPort: s.Bots, billed: log}}
	bootRuntime(t, s, ctx)
	helper := addAgent(t, s, ctx, sp.ID, "helper", "g-helper")
	addSandbox(t, s, ctx, sp.ID)
	if _, err := s.AskDirect(ctx, owner, helper.ID, "hello", nil); err != nil {
		t.Fatal(err)
	}
	got := log.all()
	if len(got) != 1 || got[0].payer != owner || got[0].bot != helper.ID {
		t.Fatalf("a direct message was billed %+v; want one turn billed to the person", got)
	}
}

// A turn that cannot be paid for — the wallet or the project's budget is spent —
// never starts and costs nothing, and the room says why.
func TestTurnsThatCannotBePaidForDoNotStartOrBill(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "budget", "")
	if err != nil {
		t.Fatal(err)
	}
	room, _ := s.generalRoom(ctx, sp.ID)
	log := &billLog{}
	var spent error
	s.Bots = sandboxBots{mentionBots{BotPort: s.Bots, billed: log, fundsErr: &spent}}
	rt := bootRuntime(t, s, ctx)
	helper := addAgent(t, s, ctx, sp.ID, "helper", "g-helper")
	addSandbox(t, s, ctx, sp.ID)
	spent = errs.New(errs.CodeFinance, "project budget exceeded")

	id, _ := identity.New(s.K.NodeID())
	m := &message.Message{Entity: entity.Entity{ID: id, CreatedAt: time.Now()}, SpaceID: sp.ID, RoomID: room.ID, SenderID: owner, Body: "@helper go"}
	m.SetMentions([]string{helper.ID.String()})
	replies, err := s.DeliverMentions(ctx, sp.ID, room.ID, m)
	if err == nil || !strings.Contains(err.Error(), "budget exceeded") {
		t.Fatalf("a mention past the budget returned %v", err)
	}
	if len(rt.prompts) != 0 || len(log.all()) != 0 {
		t.Fatalf("a refused turn ran (%d prompts) or was billed (%+v)", len(rt.prompts), log.all())
	}
	if len(replies) != 1 || !strings.Contains(replies[0].Reply, "budget exceeded") || strings.Contains(replies[0].Reply, "LLM usage") {
		t.Fatalf("people were not told why: %+v", replies)
	}
	// A direct message is refused the same way.
	if _, err := s.AskDirect(ctx, owner, helper.ID, "hello", nil); err == nil || len(rt.prompts) != 0 || len(log.all()) != 0 {
		t.Fatalf("a refused direct message ran or was billed: %v %d %+v", err, len(rt.prompts), log.all())
	}
	// Once there is room again, the same mention runs and is billed once.
	spent = nil
	if _, err := s.DeliverMentions(ctx, sp.ID, room.ID, m); err != nil {
		t.Fatal(err)
	}
	if len(rt.prompts) != 1 || len(log.all()) != 1 {
		t.Fatalf("after the budget was raised: %d prompts, %d bills", len(rt.prompts), len(log.all()))
	}
	// Resuming a waiting agent is gated too.
	rt.waiting["g-helper"] = true
	rt.waitRoom = room.ID.String()
	spent = errs.New(errs.CodeFinance, "project budget exceeded")
	answer := &message.Message{Entity: entity.Entity{ID: id, CreatedAt: time.Now()}, SpaceID: sp.ID, RoomID: room.ID, SenderID: owner, Body: "blue"}
	before := len(log.all())
	if _, err := s.DeliverMentions(ctx, sp.ID, room.ID, answer); err == nil || len(rt.replies) != 0 || len(log.all()) != before {
		t.Fatalf("a refused resume ran or was billed: %v replies=%d bills=%d", err, len(rt.replies), len(log.all()))
	}
}

func TestAFailedTurnTellsPeopleOneSentenceAndKeepsTheDetailForAdmins(t *testing.T) {
	cases := []struct {
		err      error
		contains string
		hides    string
	}{
		{errs.New(errs.CodeUnavailable, "the agent runtime did not become healthy at http://tradera-deepagents:8000"), "temporarily unavailable", "tradera-deepagents"},
		{errs.New(errs.CodeVMM, "OpenAIInvalidRequestError: Error code: 400 - thought_signature"), "ran into a problem", "thought_signature"},
		{context.Canceled, "was stopped", "canceled"},
		{&refusedError{errs.New(errs.CodeFinance, "insufficient balance to run metered execution")}, "insufficient balance", ""},
	}
	for _, c := range cases {
		got := userFacingFailure(c.err)
		if !strings.Contains(got, c.contains) || (c.hides != "" && strings.Contains(got, c.hides)) {
			t.Errorf("%v -> %q; want it to contain %q and hide %q", c.err, got, c.contains, c.hides)
		}
	}
}

// An agent reads and writes the project's stored files as a member of the
// space; a turn that forbids the sandbox forbids them too.
func TestAgentsReachTheProjectFilesWithoutTheSandboxTool(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "files", "")
	if err != nil {
		t.Fatal(err)
	}
	s.Bots = sandboxBots{mentionBots{BotPort: s.Bots}}
	agent := addAgent(t, s, ctx, sp.ID, "helper", "g-helper")
	for _, op := range []string{"read", "write"} {
		body := []byte(`{"space":"` + sp.ID.String() + `","operation":"` + op + `","path":"AGENTS.md","content":"x"}`)
		req := &api.ActionRequest{Caller: api.Caller{ID: agent.AccountID, Kind: "bot"}, Body: body}
		if _, err := s.sandboxFilesAction(ctx, req); err != nil {
			t.Fatalf("%s as an agent: %v", op, err)
		}
		denied := vmm.WithExecution(ctx, vmm.Execution{NoSandbox: true})
		if _, err := s.sandboxFilesAction(denied, req); errs.CodeOf(err) != errs.CodePermission {
			t.Fatalf("%s with the sandbox disabled: %v", op, err)
		}
	}
}

// A message in a project that has never had a computer does not create one:
// the agent gets it when it first runs something.
func TestATurnDoesNotCreateTheProjectsComputer(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "new project", "")
	if err != nil {
		t.Fatal(err)
	}
	room, _ := s.generalRoom(ctx, sp.ID)
	s.Bots = sandboxBots{mentionBots{BotPort: s.Bots}}
	rt := bootRuntime(t, s, ctx)
	a := addAgent(t, s, ctx, sp.ID, "alpha", "g-a")
	msg := &message.Message{Entity: entity.Entity{CreatedAt: time.Now()}, SpaceID: sp.ID, RoomID: room.ID, SenderID: owner, Body: "tell me a joke"}
	msg.SetMentions([]string{a.ID.String()})
	if _, err := s.DeliverMentions(ctx, sp.ID, room.ID, msg); err != nil {
		t.Fatal(err)
	}
	if len(rt.prompts) != 1 || rt.prompts[0].Sandbox.VMID != "" {
		t.Fatalf("turn = %+v", rt.prompts)
	}
	if id, ok := s.sandboxBotID(ctx, sp.ID); ok {
		t.Fatalf("a computer was created for a message that used none: %s", id)
	}
}
