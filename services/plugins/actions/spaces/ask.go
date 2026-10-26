package spaces

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/usage/models"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// AskBot routes a message to a bot within a space. It is the universal
// bot-interaction entry point: people, agents, the shared sandbox and app
// backends all talk to each other through it.
//   - agents run a turn in the room the ask was made from;
//   - docker/container/modal bots (the shared sandbox) execute the body as a
//     shell command;
//   - tool backends (external MCP, managed elpian/quickjs/docker, installed in
//     the space's sandbox) receive {"function","payload"} as a microtool call;
//   - wasm app backends receive the body as their input.
//
// [attachments] are files sent with the ask.
func (s *Service) AskBot(ctx context.Context, spaceID, botID identity.ID, body string, attachments []vmm.FileAttachment, history []vmm.ChatMessage) (string, error) {
	roomID := identity.ID{}
	if room := vmm.RoomFrom(ctx); room != "" {
		parsed, err := identity.Parse(room)
		if err != nil {
			return "", errs.InvalidArgument("invalid execution room")
		}
		roomID = parsed
	}
	if err := helper.CheckContextAccess(ctx, s.R, spaceID, roomID, true); err != nil {
		return "", err
	}
	rec, err := s.Bots.GetBot(ctx, botID)
	if err != nil {
		return "", err
	}
	if !helper.InternalAccess(ctx) {
		if err := helper.CheckSpaceAccess(ctx, s.R, rec.AccountID, spaceID, roomID, false); err != nil {
			return "", err
		}
	}
	// Reject machine backends before EnsureVM can start or contact one.
	// A tool installed into the space runs on the sandbox too.
	machine := (!rec.IsToolBackend() && (rec.VMType == bot.VMTypeDocker || rec.VMType == bot.VMTypeContainer || rec.VMType == bot.VMTypeModal)) || rec.VMType == bot.VMTypeInstalled
	if vmm.ExecutionFrom(ctx).NoSandbox && !isAgentRuntime(rec) && machine {
		return "", errs.Permission("sandbox access is disabled for this request")
	}
	// Rebuild the VM runtime when the daemon restarted and the adapter lost it.
	if err := s.Bots.EnsureVM(ctx, rec); err != nil {
		return "", err
	}
	vm := s.K.VMMFor(vmm.Type(bot.AgentVMType(rec.VMType)))
	if rec.Kind != bot.KindAgent {
		vm = s.K.VMMFor(vmm.Type(rec.VMType))
	}
	if vm == nil {
		return "", errs.New(errs.CodeUnavailable, "no VMM adapter for "+string(rec.VMType))
	}
	if isAgentRuntime(rec) {
		// The ask is a turn of the agent in the room it was made from.
		return s.promptAgent(ctx, spaceID, roomID, rec, helper.Actor(ctx), body, "", attachments)
	}
	if rec.IsToolBackend() {
		// Every tool backend — an external MCP server, a managed Elpian VM,
		// QuickJS or docker service, or one installed into this space's
		// sandbox — is called the same way, in the scope of this ask.
		execution := vmm.ExecutionFrom(ctx)
		execution.ActorID = helper.Actor(ctx).String()
		execution.SpaceID = spaceID.String()
		execution.RoomID = roomID.String()
		ctx = vmm.WithExecution(ctx, execution)
		var reply string
		err := bridge.Invoke(ctx, s.K, "tools", "InvokeTool", []any{ctx, botID.String(), body}, &reply)
		return reply, err
	}
	switch rec.VMType {
	case bot.VMTypeDocker, bot.VMTypeContainer, bot.VMTypeModal:
		// Docker/container/Modal bots are the shared per-space sandbox; run the
		// command there.
		return s.SandboxExec(ctx, spaceID, body)
	case bot.VMTypeWASM:
		if wm, ok := vm.(interface {
			Send(ctx context.Context, vmID, message string) (string, error)
		}); ok {
			return wm.Send(ctx, rec.VMID, body)
		}
	}
	return "", errs.New(errs.CodeUnavailable, "bot VM does not support ask")
}

// spaceAskAction implements spaces.ask.
type spaceAskAction struct{ s *Service }

func (a *spaceAskAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "ask", Summary: "Ask a bot (agent, sandbox or app) inside a space"}
}
func (a *spaceAskAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space       string            `json:"space"`
		Room        string            `json:"room,omitempty"`
		Bot         string            `json:"bot"`
		Body        string            `json:"body"`
		History     []vmm.ChatMessage `json:"history,omitempty"`
		Attachments []string          `json:"attachments,omitempty"` // file ids sent with the ask
		// Raw returns a sandbox command's outcome (exit code and output) instead
		// of failing on a non-zero exit, so an agent can read why it failed.
		Raw bool `json:"raw,omitempty"`
		// Tool runs one of the space's platform tools (file_send, image_generate,
		// proxy_create, routine_create, ...) with Args, instead of asking a bot.
		Tool string          `json:"tool,omitempty"`
		Args json.RawMessage `json:"args,omitempty"`
		// Thread runs the ask in one of the room's threads (its own history).
		Thread string `json:"thread,omitempty"`
		// TempThread runs an agent's ask in a temporary thread of the room,
		// opened for it and deleted when the agent is done: a fresh, isolated
		// conversation for each ask (how apps call agents).
		TempThread bool `json:"temp_thread,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	if _, err := a.s.SpaceMembership(ctx, spaceID, req.Caller.ID); err != nil {
		return nil, errs.Permission("not a member of the space")
	}
	atts, err := a.s.ResolveAttachments(ctx, req.Caller.ID, in.Attachments)
	if err != nil {
		return nil, err
	}
	var roomID identity.ID
	if in.Room != "" {
		roomID, err = identity.Parse(in.Room)
		if err != nil {
			return nil, errs.InvalidArgument("invalid room id")
		}
	}
	if in.Thread != "" {
		threadID, terr := identity.Parse(in.Thread)
		if terr != nil {
			return nil, errs.InvalidArgument("invalid thread id")
		}
		thread, terr := a.s.GetRoom(ctx, threadID)
		if terr != nil || !thread.IsThread() || thread.SpaceID != spaceID {
			return nil, errs.NotFound("no such thread in this space")
		}
		if !roomID.IsZero() && a.s.mainRoom(ctx, roomID) != a.s.mainRoom(ctx, threadID) {
			return nil, errs.InvalidArgument("the thread belongs to another room")
		}
		roomID = threadID
	}
	if in.TempThread && in.Tool == "" && in.Thread == "" {
		var resp *api.ActionResponse
		room := a.s.ensureRoom(ctx, spaceID, roomID)
		if room.IsZero() {
			return nil, errs.NotFound("no room in space")
		}
		err := a.s.WithTempThread(ctx, spaceID, room, req.Caller.ID, "", func(thread identity.ID) error {
			inner := in
			inner.Room, inner.Thread, inner.TempThread = thread.String(), "", false
			// A fresh thread has no history: what the caller kept of its
			// conversation with the agent travels with the ask.
			inner.Body, inner.History = withHistory(in.History, in.Body), nil
			body, _ := json.Marshal(inner)
			sub := *req
			sub.Body = body
			var herr error
			resp, herr = a.Handle(ctx, &sub)
			return herr
		})
		return resp, err
	}
	// Resolve the room so the live working status has a room to be published
	// to, and wire the activity hook into ctx for the whole ask.
	var done func()
	if statusRoom := a.s.ensureRoom(ctx, spaceID, roomID); !statusRoom.IsZero() {
		if vmm.StatusFrom(ctx) == nil {
			ctx, done = a.s.activityWriter(ctx, statusRoom)
		}
		roomID = statusRoom
	}
	if done != nil {
		defer done()
	}
	// An agent asking inside a run keeps the run's scope: the person who
	// started it pays and authorizes, and its tools are attributed to the
	// agent. A person's ask starts its own scope.
	payer := a.s.payer(ctx, req.Caller.ID)
	ctx = vmm.WithRoom(helper.WithActor(ctx, payer), roomID.String())
	if payer == req.Caller.ID {
		ctx = vmm.WithRequestIntent(ctx, in.Body, atts)
	}
	if in.Tool != "" {
		return a.s.askTool(ctx, spaceID, roomID, req.Caller.ID, in.Tool, in.Args)
	}
	var botID identity.ID
	if in.Bot == "sandbox" {
		// The space's computer by name: a space that has none yet gets it now,
		// the first time something is actually run on it.
		sandbox, serr := a.s.SandboxEnsure(ctx, spaceID)
		if serr != nil {
			return nil, serr
		}
		botID = sandbox.ID
	} else if botID, err = identity.Parse(in.Bot); err != nil {
		return nil, errs.InvalidArgument("invalid bot id")
	}
	ctx = vmm.WithInvocationUsage(ctx)
	if payer == req.Caller.ID {
		ctx = vmm.WithExecution(ctx, vmm.Execution{ActorID: payer.String(), SpaceID: spaceID.String(), RoomID: roomID.String(), AgentID: botID.String()})
	}
	startTime := time.Now()
	rec, gerr := a.s.Bots.GetBot(ctx, botID)
	// Hard enforcement: the payer must be able to cover the bot before it runs.
	if err := a.s.Bots.EnsureFunds(ctx, payer, botID); err != nil {
		return nil, err
	}
	reply, err := a.s.AskBot(ctx, spaceID, botID, in.Body, atts, in.History)
	out := map[string]any{"bot_id": botID.String(), "reply": reply}
	if err != nil {
		// A sandbox command that ran and failed is an outcome the caller asked
		// to read, not a transport failure.
		if !in.Raw || errs.CodeOf(err) != vmm.CodeToolExecutionFailed {
			return nil, err
		}
	}
	if in.Raw {
		code, output := commandOutcome(reply)
		out["exit_code"], out["output"] = code, output
	}
	botName := ""
	if gerr == nil {
		botName = rec.Name
	}
	_, err = a.s.Bots.BillAndRecordUsage(ctx, payer, botID, elapsedSeconds(startTime), "space ask",
		usage.UsageCtx{SpaceID: spaceID, RoomID: roomID, BotName: botName, RequestID: usage.RequestIDFrom(ctx), Kind: usage.KindAsk})
	if err != nil {
		return nil, err
	}
	return helper.JSON(out)
}

// askTool runs one of the space's platform tools for the asking account. An
// agent's tools run under its own name inside the run's scope.
func (s *Service) askTool(ctx context.Context, spaceID, roomID, caller identity.ID, tool string, args json.RawMessage) (*api.ActionResponse, error) {
	name := s.accountName(ctx, caller)
	if rec, err := s.botForMember(ctx, caller); err == nil {
		name = rec.Name
		policy := vmm.ExecutionFrom(ctx)
		if policy.AgentID != rec.ID.String() {
			policy.AgentID = rec.ID.String()
			ctx = vmm.WithExecution(ctx, policy)
		}
	}
	argsJSON := "{}"
	if len(args) > 0 {
		argsJSON = string(args)
	}
	result, err := s.ToolDispatch(ctx, spaceID.String(), name, tool, argsJSON)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"tool": tool, "result": result})
}

// withHistory prefixes an ask with the conversation that led to it, for an
// agent that starts in a fresh thread. Only the latest 20 turns are kept.
func withHistory(history []vmm.ChatMessage, body string) string {
	if len(history) == 0 {
		return body
	}
	if len(history) > 20 {
		history = history[len(history)-20:]
	}
	var b strings.Builder
	b.WriteString("Our conversation so far:\n")
	for _, m := range history {
		who := "Me"
		if m.Role == "assistant" {
			who = "You"
		}
		b.WriteString(who + ": " + clipTrace(strings.TrimSpace(m.Content), 2000) + "\n")
	}
	b.WriteString("\nNow: " + body)
	return b.String()
}

// commandOutcome splits a sandbox reply ("exit=N\n<output>") into its exit code
// and output. Unknown means -1.
func commandOutcome(reply string) (int, string) {
	header, rest, found := strings.Cut(reply, "\n")
	raw, ok := strings.CutPrefix(header, "exit=")
	if !ok {
		return -1, reply
	}
	code, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil {
		return -1, reply
	}
	if !found {
		rest = ""
	}
	return code, rest
}

// sandboxExecAction implements spaces.sandbox_exec.
type sandboxExecAction struct{ s *Service }

func (a *sandboxExecAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "sandbox_exec", Summary: "Run a shell command in the shared space sandbox"}
}
func (a *sandboxExecAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space   string `json:"space"`
		Command string `json:"command"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	if err := helper.CheckSpaceAccess(ctx, a.s.R, req.Caller.ID, spaceID, identity.ID{}, true, "sandbox_exec"); err != nil {
		return nil, err
	}
	// Hard enforcement: the caller must be able to pay for the sandbox before it
	// runs the command.
	sandboxBotID, err := a.s.SandboxBotID(ctx, spaceID)
	if err != nil {
		return nil, err
	}
	// The command is the project's: its budget applies and its usage records it.
	ctx = billingScope(ctx, spaceID, identity.ID{}, sandboxBotID, req.Caller.ID)
	if err := a.s.Bots.EnsureFunds(ctx, req.Caller.ID, sandboxBotID); err != nil {
		return nil, err
	}
	startTime := time.Now()
	out, err := a.s.SandboxExec(ctx, spaceID, in.Command)
	if err != nil {
		return nil, err
	}
	if err := a.s.Bots.BillUsage(ctx, req.Caller.ID, sandboxBotID, elapsedSeconds(startTime), "sandbox exec"); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"output": out})
}

// sandboxStatusAction implements spaces.sandbox_status.
type sandboxStatusAction struct{ s *Service }

func (a *sandboxStatusAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "sandbox_status", Summary: "Shared space sandbox status"}
}
func (a *sandboxStatusAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	if err := helper.CheckSpaceAccess(ctx, a.s.R, req.Caller.ID, spaceID, identity.ID{}, false); err != nil {
		return nil, err
	}
	st, err := a.s.SandboxStatus(ctx, spaceID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(st)
}

// sandboxStartAction implements spaces.sandbox_start.
type sandboxStartAction struct{ s *Service }

func (a *sandboxStartAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "sandbox_start", Summary: "Start the shared space sandbox"}
}
func (a *sandboxStartAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	if err := helper.CheckSpaceAccess(ctx, a.s.R, req.Caller.ID, spaceID, identity.ID{}, true, "sandbox_exec"); err != nil {
		return nil, err
	}
	rec, err := a.s.SandboxStart(ctx, spaceID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"bot_id": rec.ID.String(), "status": rec.Status})
}

// sandboxStopAction implements spaces.sandbox_stop.
type sandboxStopAction struct{ s *Service }

func (a *sandboxStopAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "sandbox_stop", Summary: "Stop the shared space sandbox (kept for reuse)"}
}
func (a *sandboxStopAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	if err := helper.CheckSpaceAccess(ctx, a.s.R, req.Caller.ID, spaceID, identity.ID{}, true, "sandbox_exec"); err != nil {
		return nil, err
	}
	rec, err := a.s.SandboxStop(ctx, spaceID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"bot_id": rec.ID.String(), "status": rec.Status})
}

// toolsListAction implements spaces.tools_list.
type toolsListAction struct{ s *Service }

func (a *toolsListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "tools_list", Summary: "List tools (apps and the sandbox) available to agents in a space"}
}
func (a *toolsListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Room  string `json:"room,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	var roomID identity.ID
	if in.Room != "" {
		roomID, err = identity.Parse(in.Room)
		if err != nil {
			return nil, errs.InvalidArgument("invalid room id")
		}
	}
	if err := helper.CheckSpaceAccess(ctx, a.s.R, req.Caller.ID, spaceID, roomID, false); err != nil {
		return nil, err
	}
	tools, err := a.s.SpaceTools(ctx, spaceID, roomID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"tools": tools})
}
