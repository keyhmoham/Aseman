package spaces

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/spaces/models/turn"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// teamRuntime plays a lead that hands work to a helper (as its message_send
// with a mention does) and finishes, and a helper that works until stopped.
type teamRuntime struct {
	*fakeAgentRuntime
	s             *Service
	helper        *bot.Bot
	helperStarted chan struct{}
	helperEnded   chan error
	once          sync.Once
}

func (r *teamRuntime) Prompt(ctx context.Context, vmID string, t vmm.AgentTurn) (string, error) {
	if t.Agent.BotID == r.helper.ID.String() {
		r.once.Do(func() { close(r.helperStarted) })
		select {
		case <-ctx.Done():
			r.helperEnded <- ctx.Err()
			return "", ctx.Err()
		case <-time.After(5 * time.Second):
			r.helperEnded <- nil
			return "helper finished", nil
		}
	}
	// The lead: delegate, as an agent's message_send does (the delivery keeps
	// the run's scope but not its deadline), then finish its own part.
	sp, _ := identity.Parse(t.SpaceID)
	room, _ := identity.Parse(t.RoomID)
	id, _ := identity.New(1)
	now := time.Now().UTC()
	msg := &message.Message{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		SpaceID: sp, RoomID: room, SenderID: identity.MustParse(t.Agent.AccountID), Body: "@helper research this"}
	msg.SetMentions([]string{r.helper.ID.String()})
	r.s.deliverMentionsAsync(context.WithoutCancel(ctx), sp, room, msg, msg.SenderID)
	return "I asked the helper", nil
}

func TestStopEndsTheWholeTeam(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "team", "")
	if err != nil {
		t.Fatal(err)
	}
	room, err := s.generalRoom(ctx, sp.ID)
	if err != nil {
		t.Fatal(err)
	}
	s.Bots = sandboxBots{mentionBots{BotPort: s.Bots}}
	rt := &teamRuntime{fakeAgentRuntime: newFakeAgentRuntime(), s: s,
		helperStarted: make(chan struct{}), helperEnded: make(chan error, 1)}
	if err := s.K.(*kernel.Kernel).Register(rt); err != nil {
		t.Fatal(err)
	}
	if err := s.K.(*kernel.Kernel).Boot(ctx, []string{"harness"}); err != nil {
		t.Fatal(err)
	}
	lead := addAgent(t, s, ctx, sp.ID, "lead", "lead-vm")
	rt.helper = addAgent(t, s, ctx, sp.ID, "helper", "helper-vm")

	tr, err := s.SubmitRoomTurn(ctx, owner, sp.ID, room.ID, "stop-team", "build it", "", []string{lead.ID.String()}, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	finished := make(chan struct{})
	go func() {
		s.executeTurn(ctx, *tr)
		close(finished)
	}()
	select {
	case <-rt.helperStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("the helper never started")
	}

	// The lead is done but its helper works: the turn is still running, so
	// Stop is still offered.
	var current turn.Turn
	if err := s.R.Get(ctx, "room_turns", tr.ID, &current); err != nil {
		t.Fatal(err)
	}
	if current.Status != "running" {
		t.Fatalf("turn %s while its helper works, want running", current.Status)
	}
	select {
	case <-finished:
		t.Fatal("the turn ended before its helper")
	default:
	}

	if _, err := s.turnCancel(ctx, &api.ActionRequest{Caller: api.Caller{ID: owner, Kind: "user"},
		Body: []byte(`{"turn":"` + tr.ID.String() + `"}`)}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-rt.helperEnded:
		if err == nil {
			t.Fatal("the helper finished its work instead of stopping")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Stop did not reach the helper")
	}
	select {
	case <-finished:
	case <-time.After(3 * time.Second):
		t.Fatal("the turn did not end after Stop")
	}
	if err := s.R.Get(ctx, "room_turns", tr.ID, &current); err != nil {
		t.Fatal(err)
	}
	if current.Status != "cancelled" {
		t.Fatalf("turn %s, want cancelled", current.Status)
	}
	// Work of the stopped run that arrives late is refused.
	late := vmm.WithExecution(ctx, vmm.Execution{RunID: tr.ID.String(), SpaceID: sp.ID.String(), RoomID: room.ID.String()})
	if !s.runStopped(late) {
		t.Fatal("a stopped run accepts new work")
	}
	if _, err := s.SandboxExec(late, sp.ID, "echo hi"); err == nil || !strings.Contains(err.Error(), "stopped") {
		t.Fatalf("a stopped run ran a command: %v", err)
	}
}

func TestTeamWorkWaitsForEveryoneAndJoinsOnlyItsRun(t *testing.T) {
	s := &Service{}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	run := s.openRun("turn-1", identity.ID{}, cancel)

	inRun := vmm.WithExecution(context.Background(), vmm.Execution{RunID: "turn-1"})
	member, done := s.joinRun(inRun)
	waited := make(chan struct{})
	go func() {
		run.waitTeam(ctx)
		close(waited)
	}()
	select {
	case <-waited:
		t.Fatal("the turn did not wait for its member")
	case <-time.After(50 * time.Millisecond):
	}
	done()
	select {
	case <-waited:
	case <-time.After(time.Second):
		t.Fatal("the turn kept waiting after its member was done")
	}
	if member.Err() == nil {
		t.Fatal("a finished member's context is still open")
	}

	// Work outside any run, or of another run, is left alone.
	other, otherDone := s.joinRun(vmm.WithExecution(context.Background(), vmm.Execution{RunID: "turn-2"}))
	defer otherDone()
	s.stopRun("turn-1")
	if other.Err() != nil {
		t.Fatal("stopping one run stopped another")
	}
	if ctx.Err() == nil {
		t.Fatal("stopping the run left the turn's own work running")
	}
	if late, _ := s.joinRun(inRun); late.Err() == nil {
		t.Fatal("a stopped run took on new work")
	}
}

func TestRunMarkGoesWithCommandsAndStopEndsThem(t *testing.T) {
	if got := runEnv("0123abcd"); got != "export ASEMAN_RUN='0123abcd' && " {
		t.Fatalf("runEnv = %q", got)
	}
	if runEnv("x'; rm -rf /") != "" || runEnv("") != "" {
		t.Fatal("an unsafe run id was put in a command")
	}
	if cmd := killRunCommand("0123abcd"); !strings.Contains(cmd, "grep -qx 'ASEMAN_RUN=0123abcd'") || !strings.Contains(cmd, "kill -9") {
		t.Fatalf("kill command = %q", cmd)
	}
}
