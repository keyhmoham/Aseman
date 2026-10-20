package spaces

import (
	"context"
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/jsonpatch"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
	"github.com/tradera/tradera/plugins/actions/spaces/models/space"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	usage "github.com/tradera/tradera/plugins/actions/usage/models"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
	vmm "github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// Every agent runs on the deep agents runtime and is reached only through
// space messaging: a room message (or ask) becomes a turn, the reply goes back
// into the room as an answer to that message, and everything else the agent
// does on the platform goes through the space's action API (spaces.ask for
// tools and the shared sandbox, spaces.message_send and users.dm_send to talk).
// This file routes rooms to the runtime.

// isAgentRuntime reports whether a bot is an agent served by the runtime.
func isAgentRuntime(rec *bot.Bot) bool {
	return rec != nil && rec.Kind == bot.KindAgent && bot.AgentVMType(rec.VMType) == bot.VMTypeDeepAgents
}

func (s *Service) agentRuntime(rec *bot.Bot) (vmm.AgentRuntime, error) {
	rt, ok := s.K.VMMFor(vmm.TypeDeepAgents).(vmm.AgentRuntime)
	if !ok || rt == nil {
		return nil, errs.New(errs.CodeUnavailable, "the agent runtime is not active on this node")
	}
	return rt, nil
}

// reserveSandbox gives a turn the space's computer without starting it: most
// messages are answered by the model alone, so the computer wakes only when
// the agent first runs a command on it (SandboxExec starts it). While the turn
// runs the computer is kept from idling out. A space that has no computer yet
// is not given one here either: creating it is starting it, so that too waits
// for the agent's first command (spaces.ask with bot "sandbox").
func (s *Service) reserveSandbox(ctx context.Context, spaceID identity.ID) (vmm.SandboxRef, func(), error) {
	if err := s.retireLegacySandbox(ctx, spaceID); err != nil {
		return vmm.SandboxRef{}, nil, err
	}
	ref := vmm.SandboxRef{}
	if botID, ok := s.sandboxBotID(ctx, spaceID); ok {
		if rec, err := s.Bots.GetBot(ctx, botID); err == nil {
			ref = vmm.SandboxRef{Type: vmm.Type(rec.VMType), VMID: rec.VMID}
		}
	}
	key := spaceID.String()
	s.sandboxMu.Lock()
	st := s.sandboxes[key]
	if st == nil {
		st = &sandboxState{}
		s.sandboxes[key] = st
	}
	st.active++
	s.sandboxMu.Unlock()
	release := func() {
		s.sandboxMu.Lock()
		if current := s.sandboxes[key]; current != nil && current.active > 0 {
			current.active--
		}
		s.sandboxMu.Unlock()
		s.touch(spaceID)
	}
	return ref, release, nil
}

// legacySandboxImage is the sandbox image spaces used before the sandbox computer.
const legacySandboxImage = "node:20-alpine"

// retireLegacySandbox replaces a space sandbox still running the legacy image
// (which cannot host agent engines) with a fresh sandbox computer. The old
// sandbox is stopped and detached from the space, never deleted, so its files
// stay recoverable from its stopped container.
func (s *Service) retireLegacySandbox(ctx context.Context, spaceID identity.ID) error {
	if s.sandboxImage() == legacySandboxImage {
		return nil
	}
	botID, ok := s.sandboxBotID(ctx, spaceID)
	if !ok {
		return nil
	}
	rec, err := s.Bots.GetBot(ctx, botID)
	if err != nil || rec.ImageRef != legacySandboxImage {
		return nil
	}
	s.sandboxEnsureMu.Lock()
	defer s.sandboxEnsureMu.Unlock()
	if current, ok := s.sandboxBotID(ctx, spaceID); !ok || current != botID {
		return nil // already replaced concurrently
	}
	if rec.Status == bot.StatusRunning {
		if _, err := s.Bots.Lifecycle(ctx, rec.ID, "stop"); err != nil {
			s.L.Warn("stop legacy sandbox", "space", spaceID.String(), "error", err)
		}
	}
	if sp, err := s.GetSpace(ctx, spaceID); err == nil {
		if err := s.RemoveBot(ctx, sp.OwnerID, spaceID, rec.AccountID); err != nil {
			s.L.Warn("detach legacy sandbox", "space", spaceID.String(), "error", err)
		}
	}
	if err := s.M.Patch(ctx, spaceID, jsonpatch.Patch{{Op: "remove", Path: "sandbox/bot_id"}}); err != nil {
		return err
	}
	s.sandboxMu.Lock()
	if st := s.sandboxes[spaceID.String()]; st != nil && st.botID == botID {
		st.botID = identity.ID{}
	}
	s.sandboxMu.Unlock()
	s.L.Info("legacy sandbox retired; files remain in its stopped VM", "space", spaceID.String(), "bot", rec.ID.String(), "vm", rec.VMID)
	return nil
}

// agentTurn assembles the turn an agent receives for a room message.
func (s *Service) agentTurn(ctx context.Context, spaceID, roomID identity.ID, rec *bot.Bot, sender identity.ID, body, messageID string, atts []vmm.FileAttachment) vmm.AgentTurn {
	return vmm.AgentTurn{
		Agent:        vmm.AgentIdentity{BotID: rec.ID.String(), AccountID: rec.AccountID.String(), Name: rec.Name},
		SpaceID:      spaceID.String(),
		RoomID:       roomID.String(),
		MessageID:    messageID,
		SenderID:     sender.String(),
		SenderName:   s.accountName(ctx, sender),
		Message:      body,
		Attachments:  atts,
		NoSandbox:    vmm.ExecutionFrom(ctx).NoSandbox,
		NoMemory:     vmm.ExecutionFrom(ctx).NoMemory,
		RequestScope: vmm.ExecutionFrom(ctx).RequestScope,
	}
}

// agentScope binds the platform execution scope (actor, agent, space, room) to
// a turn's context, so every action the agent calls is authorized against it.
func agentScope(ctx context.Context, spaceID, roomID identity.ID, rec *bot.Bot, actor identity.ID) context.Context {
	policy := vmm.ExecutionFrom(ctx)
	policy.AgentID = rec.ID.String()
	policy.SpaceID = spaceID.String()
	policy.RoomID = roomID.String()
	if policy.ActorID == "" {
		policy.ActorID = actor.String()
		ctx = helper.WithActor(ctx, actor)
	}
	return vmm.WithExecution(vmm.WithRoom(ctx, roomID.String()), policy)
}

// prepareTurn resolves the room, reserves the shared sandbox for the whole turn
// (without starting it) and fills the turn's scope. The caller must call release.
func (s *Service) prepareTurn(ctx context.Context, spaceID, roomID identity.ID, rec *bot.Bot, turn *vmm.AgentTurn) (vmm.AgentRuntime, func(), error) {
	rt, err := s.agentRuntime(rec)
	if err != nil {
		return nil, nil, err
	}
	// The runtime keeps definitions in memory; rebuild after a restart.
	endVM := vmm.Trace(ctx, "agent.ensure", rec.Name)
	vmErr := s.Bots.EnsureVM(ctx, rec)
	endVM()
	if vmErr != nil {
		return nil, nil, vmErr
	}
	ref, release := vmm.SandboxRef{}, func() {}
	if turn.NoSandbox {
		// The agent engine runs on the node; the space machine stays untouched.
	} else if _, recorded := s.sandboxBotID(ctx, spaceID); recorded || s.K.VMMFor(vmm.Type(s.sandboxVMType())) != nil {
		endSandbox := vmm.Trace(ctx, "sandbox.reserve", "start or wake the project computer")
		ref, release, err = s.reserveSandbox(ctx, spaceID)
		endSandbox()
		if err != nil {
			return nil, nil, err
		}
	} else {
		// A node without a sandbox provider still runs agents; they talk and
		// use platform tools but have no shell or files.
		s.L.Warn("no sandbox provider; agent turn runs without the shared sandbox", "space", spaceID.String(), "type", string(s.sandboxVMType()))
	}
	endContext := vmm.Trace(ctx, "context", "room, people and instructions")
	turn.Context = s.agentContext(ctx, spaceID, roomID, rec)
	turn.Note = s.senderClock(ctx, turn.SenderID)
	endContext()
	// The desk as it is now: agents place, move and close card windows on it.
	if desk := s.deskNote(ctx, spaceID, roomID); desk != "" {
		turn.Note = strings.TrimSpace(turn.Note + "\n" + desk)
	}
	turn.Sandbox = ref
	return rt, release, nil
}

// promptAgent runs a triggered turn of an agent in the room and returns its
// reply. messageID is the room message that triggered the turn (if any).
func (s *Service) promptAgent(ctx context.Context, spaceID, roomID identity.ID, rec *bot.Bot, sender identity.ID, body, messageID string, atts []vmm.FileAttachment) (string, error) {
	if roomID.IsZero() {
		room, err := s.generalRoom(ctx, spaceID)
		if err != nil {
			return "", err
		}
		roomID = room.ID
	}
	endGate := vmm.Trace(ctx, "gate", "budget and wallet")
	gateErr := s.gateTurn(ctx, spaceID, roomID, rec, s.payer(ctx, sender))
	endGate()
	if gateErr != nil {
		return "", gateErr
	}
	turn := s.agentTurn(ctx, spaceID, roomID, rec, sender, body, messageID, atts)
	rt, release, err := s.prepareTurn(ctx, spaceID, roomID, rec, &turn)
	if err != nil {
		return "", err
	}
	defer release()
	return rt.Prompt(agentScope(ctx, spaceID, roomID, rec, sender), rec.VMID, turn)
}

// findAgent resolves a bot member of the space by id, account id, name or
// handle (case-insensitive, optional leading @).
func (s *Service) findAgent(ctx context.Context, spaceID identity.ID, target string) (*bot.Bot, error) {
	want := strings.ToLower(strings.TrimPrefix(strings.TrimSpace(target), "@"))
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "role": string(membership.RoleBot)},
	}, &mems); err != nil {
		return nil, err
	}
	for i := range mems {
		rec, err := s.botForMember(ctx, mems[i].MemberID)
		if err != nil {
			continue
		}
		if want == rec.ID.String() || want == rec.AccountID.String() || want == strings.ToLower(rec.Name) {
			return rec, nil
		}
	}
	return nil, errs.NotFound("no agent " + target + " in this space; check room_info")
}

// agentContext describes the space, room and its members to an agent so it
// knows its scope and who it can work with.
func (s *Service) agentContext(ctx context.Context, spaceID, roomID identity.ID, self *bot.Bot) string {
	var b strings.Builder
	// The platform-wide instructions set by the node administrator come first;
	// the agent's own persona is applied by its runtime.
	var universal string
	if err := bridge.Invoke(ctx, s.K, "settings", "Instructions", []any{ctx}, &universal); err == nil && universal != "" {
		b.WriteString("Platform instructions:\n" + universal + "\n\n")
	}
	if sp, err := s.GetSpace(ctx, spaceID); err == nil {
		fmt.Fprintf(&b, "Space: %q (id %s)", sp.Name, sp.ID.String())
		if sp.Description != "" && !vmm.ExecutionFrom(ctx).NoMemory {
			fmt.Fprintf(&b, " — %s", sp.Description)
		}
		b.WriteString("\n")
	}
	if room, err := s.GetRoom(ctx, roomID); err == nil {
		fmt.Fprintf(&b, "Room: %q (id %s)", room.Name, room.ID.String())
		if room.Topic != "" && !vmm.ExecutionFrom(ctx).NoMemory {
			fmt.Fprintf(&b, " — topic: %s", room.Topic)
		}
		b.WriteString("\n")
	}
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{Equal: map[string]any{"space_id": spaceID.String()}}, &mems); err == nil {
		var people, agents, tools []string
		seen := map[string]bool{}
		for i := range mems {
			m := mems[i]
			if !m.RoomID.IsZero() && m.RoomID != roomID {
				continue
			}
			if seen[m.MemberID.String()] {
				continue
			}
			seen[m.MemberID.String()] = true
			if m.Role != membership.RoleBot {
				people = append(people, fmt.Sprintf("%s (%s, %s)", s.accountName(ctx, m.MemberID), m.MemberID.String(), m.Role))
				continue
			}
			rec, err := s.botForMember(ctx, m.MemberID)
			if err != nil || rec.ID == self.ID {
				continue
			}
			entry := fmt.Sprintf("%s (bot %s)", rec.Name, rec.ID.String())
			if d := s.toolDescription(ctx, rec); d != "" {
				entry += ": " + clipText(d, 200)
			}
			if rec.Kind == bot.KindAgent {
				agents = append(agents, entry)
			} else {
				tools = append(tools, entry)
			}
		}
		sort.Strings(people)
		sort.Strings(agents)
		sort.Strings(tools)
		writeList(&b, "People", people)
		writeList(&b, "Other agents (delegate to them with the task tool, or message them)", agents)
		writeList(&b, "Apps", tools)
	}
	return strings.TrimSpace(b.String())
}

func writeList(b *strings.Builder, title string, items []string) {
	if len(items) == 0 {
		return
	}
	b.WriteString(title + ":\n")
	for _, it := range items {
		b.WriteString("- " + it + "\n")
	}
}

// accountName returns an account's handle (or its id when unknown).
func (s *Service) accountName(ctx context.Context, id identity.ID) string {
	var acc account.Account
	if err := s.R.Get(ctx, "accounts", id, &acc); err == nil && acc.Handle != "" {
		return acc.Handle
	}
	return id.String()
}

func parseIDs(raw ...string) ([]identity.ID, error) {
	out := make([]identity.ID, len(raw))
	for i, v := range raw {
		id, err := identity.Parse(v)
		if err != nil {
			return nil, err
		}
		out[i] = id
	}
	return out, nil
}

func clipText(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return strings.TrimSpace(s[:n]) + "…"
}

// deliverToAgent hands a room message to an agent: a person's message answers
// the question the agent is waiting on in that room (when it is addressed to
// that agent or to no one), a mention triggers a turn, and anything else is
// observed so the agent's next turn knows what was said. A reply is stored in
// the room as the agent's answer to the message.
func (s *Service) deliverToAgent(ctx context.Context, spaceID, roomID identity.ID, msg *message.Message, rec *bot.Bot, mentions []string, atts []vmm.FileAttachment) (*MentionReply, error) {
	rt, err := s.agentRuntime(rec)
	if err != nil {
		return nil, err
	}
	turn := s.agentTurn(ctx, spaceID, roomID, rec, msg.SenderID, msg.Body, msg.ID.String(), atts)
	mentioned := isMentioned(rec, mentions)
	fromAgent := s.isBotAccount(ctx, msg.SenderID)
	if !fromAgent && turn.RequestScope == "" && (mentioned || len(mentions) == 0) {
		answered, reply, err := s.answerAgent(ctx, spaceID, roomID, rec, msg.SenderID, msg.ID.String(), turn)
		if answered || err != nil {
			return reply, err
		}
	}
	if !mentioned {
		return nil, rt.Observe(ctx, rec.VMID, turn)
	}
	if fromAgent {
		// Agents hand work to each other through room messages; bound the chain
		// so agents asking each other back cannot loop forever.
		if vmm.AgentAskDepth(ctx) >= vmm.MaxAgentAskDepth {
			return nil, errs.Conflict(rec.Name + " was not started: the chain of agents asking agents is too deep; finish the work yourself or report back")
		}
		ctx = vmm.WithAgentAsk(ctx)
	}
	return s.runAgentTurn(ctx, spaceID, roomID, rec, msg.SenderID, msg.ID.String(), atts, func(ctx context.Context) (string, error) {
		if vmm.ExecutionFrom(ctx).ActorID == "" {
			ctx = vmm.WithRequestIntent(ctx, msg.Body, atts)
		}
		return s.promptAgent(ctx, spaceID, roomID, rec, msg.SenderID, msg.Body, msg.ID.String(), atts)
	})
}

// answerAgent delivers a person's message to the question rec waits on in the
// room (turn.QuestionID names one, else its oldest). When the runtime takes it
// as the answer, the agent resumes and what it says next is stored as its
// reply to the message.
func (s *Service) answerAgent(ctx context.Context, spaceID, roomID identity.ID, rec *bot.Bot, sender identity.ID, messageID string, turn vmm.AgentTurn) (bool, *MentionReply, error) {
	// Most messages answer nothing: find that out before waking a machine.
	pending := false
	if art, err := s.agentRuntime(rec); err == nil {
		if ql, ok := art.(vmm.QuestionLister); ok {
			endCheck := vmm.Trace(ctx, "answer.check", "does the message answer an open question")
			qs, qerr := ql.Questions(ctx, rec.VMID, spaceID.String())
			endCheck()
			if qerr == nil {
				if !waitsIn(qs, roomID, turn.QuestionID) {
					return false, nil, nil
				}
				pending = true
				for _, q := range qs {
					if (turn.QuestionID != "" && q.ID == turn.QuestionID) || (turn.QuestionID == "" && q.RoomID == roomID.String()) {
						policy := vmm.ExecutionFrom(ctx)
						policy.NoSandbox = policy.NoSandbox || q.NoSandbox
						policy.NoMemory = policy.NoMemory || q.NoMemory
						policy.RequestScope = q.RequestScope
						ctx = vmm.WithExecution(ctx, policy)
						turn.NoSandbox, turn.NoMemory, turn.RequestScope = policy.NoSandbox, policy.NoMemory, policy.RequestScope
						break
					}
				}
			}
		}
	}
	rt, release, err := s.prepareTurn(ctx, spaceID, roomID, rec, &turn)
	if err != nil {
		return false, nil, err
	}
	defer release()
	answered := false
	reply, err := s.runAgentTurn(ctx, spaceID, roomID, rec, sender, messageID, nil, func(ctx context.Context) (string, error) {
		// Resuming an agent is work: it must be payable like any turn.
		if pending {
			if gerr := s.gateTurn(ctx, spaceID, roomID, rec, s.payer(ctx, sender)); gerr != nil {
				return "", gerr
			}
		}
		ok, reply, err := rt.Reply(agentScope(ctx, spaceID, roomID, rec, sender), rec.VMID, turn)
		answered = ok
		if !ok && err == nil {
			return "", errNoTurn // the message answered nothing; the agent did no work
		}
		return reply, err
	})
	var refused *refusedError
	if errors.As(err, &refused) {
		// The answer was meant for the waiting agent but it could not be paid
		// to resume: say so (the question stays open) rather than drop it.
		return true, reply, err
	}
	if !answered {
		return false, nil, nil
	}
	return true, reply, err
}

// waitsIn reports whether one of the questions is open in the room (the one
// named by questionID, when given).
func waitsIn(qs []vmm.AgentQuestion, roomID identity.ID, questionID string) bool {
	for _, q := range qs {
		if questionID != "" {
			if q.ID == questionID {
				return true
			}
			continue
		}
		if q.RoomID == roomID.String() {
			return true
		}
	}
	return false
}

// refusedError says a turn was not started because it could not be paid for.
type refusedError struct{ err error }

func (e *refusedError) Error() string { return e.err.Error() }
func (e *refusedError) Unwrap() error { return e.err }

// gateTurn is the check before an agent turn starts: its payer's wallet and
// the project's budget must cover at least the turn's minimum cost. A turn
// that fails it does not run and is not billed.
func (s *Service) gateTurn(ctx context.Context, spaceID, roomID identity.ID, rec *bot.Bot, payer identity.ID) error {
	if err := s.Bots.EnsureFunds(billingScope(ctx, spaceID, roomID, rec.ID, payer), payer, rec.ID); err != nil {
		return &refusedError{err}
	}
	return nil
}

// errNoTurn is returned by a turn's run function when it found nothing to run
// (a message that answers no question), so the turn is neither billed nor stored.
var errNoTurn = errors.New("no agent turn ran")

// runAgentTurn runs one agent turn for the person the delivery acts for,
// bills it and stores the reply in the room as an answer to messageID.
func (s *Service) runAgentTurn(ctx context.Context, spaceID, roomID identity.ID, rec *bot.Bot, sender identity.ID, messageID string, atts []vmm.FileAttachment, run func(context.Context) (string, error)) (*MentionReply, error) {
	ctx, actor := actingAs(ctx, sender)
	agentCtx := vmm.WithInvocationUsage(ctx)
	started := time.Now()
	reply, runErr := run(agentCtx)
	if errors.Is(runErr, errNoTurn) {
		return nil, nil // nothing ran: nothing to bill or store
	}
	// A turn that could not start — its payer's wallet or the project's budget
	// is spent — did no work, so it costs nothing; people still see why.
	var refused *refusedError
	notStarted := errors.As(runErr, &refused)
	uc := usage.UsageCtx{SpaceID: spaceID, RoomID: roomID, BotName: rec.Name, RequestID: usage.RequestIDFrom(ctx), Kind: usage.KindMention}
	var derr error
	if !notStarted {
		_, derr = s.billAgentTurn(agentCtx, actor, rec, started, uc)
		if derr != nil && runErr == nil {
			runErr = derr
		}
	}
	if runErr != nil {
		s.L.Warn("agent turn failed", "space", spaceID.String(), "bot", rec.ID.String(), "error", runErr)
		// People get a plain sentence; the technical error stays on the turn, where
		// the admin's project log shows it in full.
		reply = strings.TrimSpace(reply + "\n\n_(" + rec.Name + " " + userFacingFailure(runErr) + ")_")
	}
	out := &MentionReply{BotID: rec.ID.String(), BotHandle: rec.Name, Reply: reply}
	if strings.TrimSpace(reply) == "" {
		return out, runErr
	}
	msgID, err := s.storeBotReply(ctx, spaceID, roomID, rec.AccountID, reply, messageID)
	if err != nil {
		return out, err
	}
	out.MessageID = msgID.String()
	return out, runErr
}

// AgentQuestions lists the questions the space's agents are waiting on.
func (s *Service) AgentQuestions(ctx context.Context, spaceID identity.ID) ([]vmm.AgentQuestion, error) {
	lister, ok := s.K.VMMFor(vmm.TypeDeepAgents).(vmm.QuestionLister)
	if !ok || lister == nil {
		return []vmm.AgentQuestion{}, nil
	}
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "role": string(membership.RoleBot)},
	}, &mems); err != nil {
		return nil, err
	}
	out := []vmm.AgentQuestion{}
	seen := map[string]bool{}
	for i := range mems {
		rec, err := s.botForMember(ctx, mems[i].MemberID)
		if err != nil || !isAgentRuntime(rec) || seen[rec.ID.String()] {
			continue
		}
		seen[rec.ID.String()] = true
		_ = s.Bots.EnsureVM(ctx, rec)
		qs, err := lister.Questions(ctx, rec.VMID, spaceID.String())
		if err != nil {
			s.L.Warn("agent questions unavailable", "bot", rec.ID.String(), "error", err)
			continue
		}
		for _, q := range qs {
			q.BotID, q.Agent = rec.ID.String(), rec.Name
			out = append(out, q)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].AskedAt < out[j].AskedAt })
	return out, nil
}

// AnswerQuestion posts a person's answer in the room (so everyone sees it)
// and delivers it to the agent's question by id; the agent resumes and its
// next words are stored as its reply.
func (s *Service) AnswerQuestion(ctx context.Context, caller, spaceID, roomID, botID identity.ID, questionID, answer string) (*MentionReply, error) {
	if strings.TrimSpace(answer) == "" {
		return nil, errs.InvalidArgument("answer required")
	}
	rec, err := s.Bots.GetBot(ctx, botID)
	if err != nil {
		return nil, err
	}
	if !isAgentRuntime(rec) {
		return nil, errs.InvalidArgument(rec.Name + " is not an agent")
	}
	if roomID.IsZero() {
		room, err := s.generalRoom(ctx, spaceID)
		if err != nil {
			return nil, err
		}
		roomID = room.ID
	}
	msgID, err := s.storeRoomMessage(ctx, spaceID, roomID, caller, answer, message.KindMessage, "")
	if err != nil {
		return nil, err
	}
	ctx, done := s.activityWriter(ctx, roomID)
	defer done()
	turn := s.agentTurn(ctx, spaceID, roomID, rec, caller, answer, msgID.String(), nil)
	turn.QuestionID = questionID
	answered, reply, err := s.answerAgent(helper.WithActor(ctx, caller), spaceID, roomID, rec, caller, msgID.String(), turn)
	if err != nil {
		return reply, err
	}
	if !answered {
		return nil, errs.NotFound("that question is no longer open")
	}
	return reply, nil
}

// AskDirect serves a direct message to an agent. A person's conversation runs
// in their home space (whose sandbox the agent works on); an agent messaging
// another agent during a run converses inside the run's space and room.
func (s *Service) AskDirect(ctx context.Context, caller, botID identity.ID, body string, atts []vmm.FileAttachment) (string, error) {
	rec, err := s.Bots.GetBot(ctx, botID)
	if err != nil {
		return "", err
	}
	if !isAgentRuntime(rec) {
		return "", errs.InvalidArgument(rec.Name + " is not an agent")
	}
	if run := vmm.ExecutionFrom(ctx); run.SpaceID != "" && run.RoomID != "" {
		ids, perr := parseIDs(run.SpaceID, run.RoomID)
		if perr == nil {
			if _, err := s.SpaceMembership(ctx, ids[0], rec.AccountID); err == nil {
				if s.isBotAccount(ctx, caller) {
					if vmm.AgentAskDepth(ctx) >= vmm.MaxAgentAskDepth {
						return "", errs.Conflict("the chain of agents messaging agents is too deep; finish the work yourself")
					}
					ctx = vmm.WithAgentAsk(ctx)
				}
				return s.directTurn(ctx, s.payer(ctx, caller), ids[0], ids[1], rec, body, atts)
			}
		}
	}
	if err := s.Bots.EnsureFunds(ctx, caller, rec.ID); err != nil {
		return "", err
	}
	// The conversation runs where the agent works with the person: the project
	// they most recently came to share, so it sees that project's files and
	// sandbox; otherwise the person's home space.
	home, ok := s.sharedSpace(ctx, caller, rec.AccountID)
	if !ok {
		// Accounts start with no project; the first direct message to an agent
		// that shares none creates the personal workspace it works in.
		hs, err := s.HomeSpace(ctx, caller)
		if err != nil {
			handle := ""
			var acc account.Account
			if s.R.Get(ctx, "accounts", caller, &acc) == nil {
				handle = acc.Handle
			}
			hs, err = s.CreateHomeSpace(ctx, caller, handle)
		}
		if err != nil {
			return "", errs.Wrap(errs.CodeUnavailable, err, "could not open a workspace for this conversation")
		}
		home = hs
		if _, err := s.SpaceMembership(ctx, home.ID, rec.AccountID); err != nil {
			if err := s.AddBot(ctx, caller, home.ID, identity.ID{}, rec.AccountID); err != nil {
				return "", err
			}
		}
	}
	room, err := s.generalRoom(ctx, home.ID)
	if err != nil {
		return "", err
	}
	ctx, done := s.activityWriter(ctx, room.ID)
	defer done()
	ctx = vmm.WithRequestIntent(vmm.WithRoom(helper.WithActor(ctx, caller), room.ID.String()), body, atts)
	return s.directTurn(ctx, caller, home.ID, room.ID, rec, body, atts)
}

// directTurn runs a direct conversation turn of an agent and bills it to the
// person it works for.
func (s *Service) directTurn(ctx context.Context, payer, spaceID, roomID identity.ID, rec *bot.Bot, body string, atts []vmm.FileAttachment) (string, error) {
	agentCtx := vmm.WithInvocationUsage(ctx)
	started := time.Now()
	reply, runErr := s.promptAgent(agentCtx, spaceID, roomID, rec, helper.Actor(ctx), body, "", atts)
	var refused *refusedError
	if errors.As(runErr, &refused) {
		return reply, runErr // never started: nothing to bill
	}
	uc := usage.UsageCtx{SpaceID: spaceID, RoomID: roomID, BotName: rec.Name, RequestID: usage.RequestIDFrom(ctx), Kind: usage.KindAsk}
	if _, err := s.billAgentTurn(agentCtx, payer, rec, started, uc); err != nil && runErr == nil {
		runErr = err
	}
	return reply, runErr
}

// billingScope puts the project on ctx's execution scope, keeping whatever the
// scope already says. The scope is what attributes a charge to its project:
// finance enforces the project's budget against it and records the charge in
// the project's usage, so every billed action must carry it.
func billingScope(ctx context.Context, spaceID, roomID, botID, actor identity.ID) context.Context {
	e := vmm.ExecutionFrom(ctx)
	if e.SpaceID == "" {
		e.SpaceID = spaceID.String()
		if e.RoomID == "" && !roomID.IsZero() {
			e.RoomID = roomID.String()
		}
	}
	if e.AgentID == "" && !botID.IsZero() {
		e.AgentID = botID.String()
	}
	if e.ActorID == "" && !actor.IsZero() {
		e.ActorID = actor.String()
	}
	return vmm.WithExecution(ctx, e)
}

// billAgentTurn charges the payer for one agent turn: the agent's time (its
// per-minute rate, for this turn's duration) and the model tokens and images
// the turn used, which the runtime metered onto ctx's invocation usage. Every
// agent turn is billed here, once, by whoever ran it.
func (s *Service) billAgentTurn(ctx context.Context, payer identity.ID, rec *bot.Bot, started time.Time, uc usage.UsageCtx) (usage.Delta, error) {
	ctx = billingScope(ctx, uc.SpaceID, uc.RoomID, rec.ID, payer)
	delta, err := s.Bots.BillAndRecordUsage(ctx, payer, rec.ID, elapsedSeconds(started), "agent turn "+rec.Name, uc)
	if err != nil {
		s.L.Warn("bill agent turn", "bot", rec.ID.String(), "payer", payer.String(), "error", err)
	}
	return delta, err
}

// elapsedSeconds is how long something has run, in whole seconds rounded up
// (at least one): what metered executions are billed for.
func elapsedSeconds(started time.Time) int64 {
	return max(int64(math.Ceil(time.Since(started).Seconds())), 1)
}

// sharedSpace is the project a person and an agent most recently came to share
// (by when the agent joined it), other than the person's home space.
func (s *Service) sharedSpace(ctx context.Context, person, agent identity.ID) (*space.Space, bool) {
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"member_id": agent.String()}, OrderBy: "joined_at", Asc: false, Limit: 50,
	}, &mems); err != nil {
		return nil, false
	}
	for i := range mems {
		if _, err := s.SpaceMembership(ctx, mems[i].SpaceID, person); err != nil {
			continue
		}
		// The home space is the fallback, never the pick: an earlier DM may
		// have added the agent there.
		if sp, err := s.GetSpace(ctx, mems[i].SpaceID); err == nil && !sp.Home {
			return sp, true
		}
	}
	return nil, false
}

// RunScheduledTask runs a routine's task with the space's lead agent in the
// routine's room. The task is posted as the routine creator's message so the
// room shows what ran, and the lead's reply is stored as its answer.
func (s *Service) RunScheduledTask(ctx context.Context, spaceID, roomID, actor identity.ID, task string) (string, error) {
	lead, err := s.Bots.InstallTradera(ctx)
	if err != nil {
		return "", err
	}
	s.ensureTradera(ctx, spaceID)
	if roomID.IsZero() {
		room, err := s.generalRoom(ctx, spaceID)
		if err != nil {
			return "", err
		}
		roomID = room.ID
	}
	msgID, err := s.storeRoomMessage(ctx, spaceID, roomID, actor, task, message.KindMessage, "")
	if err != nil {
		return "", err
	}
	ctx, done := s.activityWriter(helper.WithActor(ctx, actor), roomID)
	defer done()
	reply, err := s.runAgentTurn(ctx, spaceID, roomID, lead, actor, msgID.String(), nil, func(ctx context.Context) (string, error) {
		return s.promptAgent(vmm.WithRequestIntent(ctx, task, nil), spaceID, roomID, lead, actor, task, msgID.String(), nil)
	})
	if reply == nil {
		return "", err
	}
	return reply.Reply, err
}

// senderClock tells the agent where the person is in time: their timezone (kept
// in their private preferences by the app) and what time it is there now, so "tell me every
// day at 9am" needs no question. Empty when the sender is not a person with a
// known timezone.
func (s *Service) senderClock(ctx context.Context, senderID string) string {
	id, err := identity.Parse(senderID)
	if err != nil || s.M == nil {
		return ""
	}
	rec, err := s.M.Get(ctx, id)
	if err != nil || rec == nil {
		return ""
	}
	prefs, _ := rec.Tree["preferences"].(map[string]any)
	zone, _ := prefs["timezone"].(string)
	loc, err := time.LoadLocation(strings.TrimSpace(zone))
	if err != nil || strings.TrimSpace(zone) == "" {
		return ""
	}
	return "The person's timezone is " + loc.String() + "; it is " + time.Now().In(loc).Format("Monday 2 January 2006, 15:04") +
		" there now. Use it for anything they ask to schedule, unless they say another timezone."
}

// userFacingFailure is what a person is told when an agent's turn fails. Errors
// are for the admin (they are kept on the turn): a person gets one sentence, except
// when the turn stopped over money (wallet or budget), which is something they can act on.
func userFacingFailure(err error) string {
	var refused *refusedError
	switch {
	case errors.As(err, &refused), errs.CodeOf(err) == errs.CodeBudgetExhausted, errs.CodeOf(err) == errs.CodeFinance:
		return "stopped: " + err.Error()
	case errors.Is(err, context.Canceled):
		return "was stopped."
	case errs.CodeOf(err) == errs.CodeUnavailable:
		return "is temporarily unavailable. Please try again in a moment."
	default:
		return "ran into a problem and couldn't finish. Please try again; if it keeps happening, tell the project's admin."
	}
}
