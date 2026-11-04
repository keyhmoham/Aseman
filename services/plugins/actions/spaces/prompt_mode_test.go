package spaces

import (
	"context"
	"testing"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

type modeBots struct {
	BotPort
	starts int
}

func (b *modeBots) Lifecycle(ctx context.Context, id identity.ID, op string) (*bot.Bot, error) {
	b.starts++
	return sandboxBots{b.BotPort}.Lifecycle(ctx, id, op)
}

func TestPromptCommandsExecuteWithRequestPolicy(t *testing.T) {
	for _, tc := range []struct {
		command             string
		noSandbox, noMemory bool
	}{
		{"/btw", true, true}, {"/ask", true, false}, {"/fresh", false, true},
	} {
		t.Run(tc.command, func(t *testing.T) {
			s, ctx := fileToolHarness(t)
			owner := idFromHex(t, "00000000000000010000000000000001")
			sp, err := s.CreateSpace(ctx, owner, "test", "")
			if err != nil {
				t.Fatal(err)
			}
			room, err := s.generalRoom(ctx, sp.ID)
			if err != nil {
				t.Fatal(err)
			}
			bots := &modeBots{BotPort: sandboxBots{mentionBots{BotPort: s.Bots}}}
			s.Bots = bots
			rt := bootRuntime(t, s, ctx)
			agent := addAgent(t, s, ctx, sp.ID, "helper", "helper-vm")
			addSandbox(t, s, ctx, sp.ID)
			// An older pending question must not swallow the command.
			rt.waiting[agent.VMID], rt.waitRoom = true, room.ID.String()
			turn, err := s.SubmitRoomTurn(ctx, owner, sp.ID, room.ID, "request", tc.command+" explain", "", []string{agent.ID.String()}, nil, false)
			if err != nil {
				t.Fatal(err)
			}
			s.executeTurn(ctx, *turn)
			if len(rt.prompts) != 1 {
				t.Fatalf("prompts=%v", rt.prompts)
			}
			got := rt.prompts[0]
			if got.Message != "explain" || got.NoSandbox != tc.noSandbox || got.NoMemory != tc.noMemory || got.RequestScope != turn.ID.String() {
				t.Fatalf("policy missing: %+v", got)
			}
			if !rt.waiting[agent.VMID] {
				t.Fatal("command resumed an older pending question")
			}
			if tc.noSandbox && (bots.starts != 0 || got.Sandbox.VMID != "") {
				t.Fatalf("sandbox used: starts=%d, ref=%+v", bots.starts, got.Sandbox)
			}
			if !tc.noSandbox && got.Sandbox.VMID == "" {
				t.Fatal("fresh request lost sandbox access")
			}
			// The computer is the turn's to use, but it starts only when the
			// agent first runs something on it.
			if bots.starts != 0 {
				t.Fatalf("the computer was started before the agent used it: starts=%d", bots.starts)
			}
		})
	}
}

func TestNoSandboxDeniesBeforeProvisioningOrToolDispatch(t *testing.T) {
	s := &Service{}
	ctx := vmm.WithExecution(context.Background(), vmm.Execution{NoSandbox: true})
	if _, err := s.SandboxEnsure(ctx, identity.ID{}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("sandbox ensure: %v", err)
	}
	for _, tool := range []string{"sandbox_exec", "file_send", "file_upload", "file_edit", "proxy_create"} {
		if _, err := s.ToolDispatch(ctx, "", "", tool, "{}"); errs.CodeOf(err) != errs.CodePermission {
			t.Errorf("%s: %v", tool, err)
		}
	}
}

func TestDelegatedTurnInheritsPromptMode(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "test", "")
	if err != nil {
		t.Fatal(err)
	}
	room, err := s.generalRoom(ctx, sp.ID)
	if err != nil {
		t.Fatal(err)
	}
	bots := &modeBots{BotPort: sandboxBots{mentionBots{BotPort: s.Bots}}}
	s.Bots = bots
	rt := bootRuntime(t, s, ctx)
	lead := addAgent(t, s, ctx, sp.ID, "lead", "lead-vm")
	child := addAgent(t, s, ctx, sp.ID, "child", "child-vm")
	addSandbox(t, s, ctx, sp.ID)
	ctx = vmm.WithExecution(ctx, vmm.Execution{ActorID: owner.String(), NoSandbox: true, NoMemory: true, RequestScope: "root-request"})
	id, _ := identity.New(s.K.NodeID())
	msg := &message.Message{Entity: entity.Entity{ID: id}, SenderID: lead.AccountID, Body: "do the delegated work"}
	msg.SetMentions([]string{child.ID.String()})
	if _, err := s.DeliverMentions(ctx, sp.ID, room.ID, msg); err != nil {
		t.Fatal(err)
	}
	if len(rt.prompts) != 1 {
		t.Fatalf("prompts=%+v", rt.prompts)
	}
	got := rt.prompts[0]
	if !got.NoSandbox || !got.NoMemory || got.RequestScope != "root-request" || bots.starts != 0 {
		t.Fatalf("delegation lost policy: %+v starts=%d", got, bots.starts)
	}
}

type modeQuestionRuntime struct{ *fakeAgentRuntime }

func (r *modeQuestionRuntime) Questions(ctx context.Context, vm, space string) ([]vmm.AgentQuestion, error) {
	qs, err := r.fakeAgentRuntime.Questions(ctx, vm, space)
	for i := range qs {
		qs[i].NoSandbox, qs[i].NoMemory, qs[i].RequestScope = true, true, "restricted-request"
	}
	return qs, err
}

func TestQuestionReplyRestoresPromptModeBeforePreparingSandbox(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "test", "")
	if err != nil {
		t.Fatal(err)
	}
	room, err := s.generalRoom(ctx, sp.ID)
	if err != nil {
		t.Fatal(err)
	}
	bots := &modeBots{BotPort: sandboxBots{mentionBots{BotPort: s.Bots}}}
	s.Bots = bots
	rt := &modeQuestionRuntime{newFakeAgentRuntime()}
	if err := s.K.(*kernel.Kernel).Register(rt); err != nil {
		t.Fatal(err)
	}
	if err := s.K.(*kernel.Kernel).Boot(ctx, []string{"harness"}); err != nil {
		t.Fatal(err)
	}
	agent := addAgent(t, s, ctx, sp.ID, "helper", "helper-vm")
	addSandbox(t, s, ctx, sp.ID)
	rt.waiting[agent.VMID], rt.waitRoom = true, room.ID.String()
	if _, err := s.AnswerQuestion(ctx, owner, sp.ID, room.ID, agent.ID, "q-"+agent.VMID, "option A"); err != nil {
		t.Fatal(err)
	}
	if len(rt.replies) != 1 {
		t.Fatalf("replies=%+v", rt.replies)
	}
	got := rt.replies[0]
	if !got.NoSandbox || !got.NoMemory || got.RequestScope != "restricted-request" || bots.starts != 0 {
		t.Fatalf("answer lost policy: %+v starts=%d", got, bots.starts)
	}
}
