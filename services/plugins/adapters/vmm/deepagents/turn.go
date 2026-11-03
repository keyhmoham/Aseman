package deepagents

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// session is one turn's access to the platform. The runtime presents its token
// to the gateway; the gateway acts as the agent's account inside the turn's
// execution scope (who started it and pays, the space, room and run, the live
// status hook and the usage meter), all carried by base.
type session struct {
	token   string
	def     *agentDef
	account identity.ID
	botID   string
	spaceID string
	roomID  string
	// personal is a person-scoped chat session (Aseman self-chat / Talk under
	// a CLI engine), not a room agent turn: serveCall dispatches as the person
	// with no space lock.
	personal bool
	// chat is a personal session's model (the assistant's), served on /llm
	// to an engine on the platform's models (DeepSeek Harness). Nil: the
	// session has no model (OpenCode brings its own).
	chat *Spec
	base context.Context

	// started and the token counters are what the turn has used so far, which
	// the node gates each model call against (the budget and the wallet).
	started time.Time
	mu      sync.Mutex
	tokIn   int64
	tokOut  int64
	// decisionCost is what the turn's decisions have cost so far (ledger
	// units, fractional), and decisionCharged the whole units of it metered.
	decisionCost    float64
	decisionCharged int64
	// Fresh turns may read only replies to handoffs made during this session.
	sentMessages map[string]bool
	attachments  map[string]bool
	// inflight counts the turn's gateway calls still being served (model,
	// decision and platform calls), which meter what they use onto the turn.
	inflight atomic.Int64
}

// begin marks one gateway call of the turn as in flight; the returned func
// ends it.
func (s *session) begin() func() {
	s.inflight.Add(1)
	return func() { s.inflight.Add(-1) }
}

// settleTimeout bounds how long a stopped turn waits for its gateway calls.
var settleTimeout = 30 * time.Second

// settle waits, when the turn was stopped, for the gateway calls it still had
// in flight: they meter what the provider already did (an interrupted model
// call, an image being made) onto the turn, and the turn is charged right
// after it returns. Without the wait that usage landed after the charge and
// was never paid.
func (s *session) settle(ctx context.Context) {
	if ctx.Err() == nil {
		return
	}
	deadline := time.Now().Add(settleTimeout)
	for s.inflight.Load() > 0 && time.Now().Before(deadline) {
		time.Sleep(25 * time.Millisecond)
	}
}

// agentPayload is the agent definition the runtime runs a turn with.
type agentPayload struct {
	Spec
	BotID     string `json:"bot_id"`
	AccountID string `json:"account_id"`
	VMID      string `json:"vm_id"`
}

// decisionPayload tells the runtime that the node's decision model is on for
// the turn: tool selection and decisions go to it (POST {gateway}/decision/
// evaluate) in cooperation with the agent's own model. Absent, the agent's
// own model decides everything.
type decisionPayload struct {
	Enabled bool   `json:"enabled"`
	Model   string `json:"model"`
	// AutoApprove: the runtime may let the decision model approve low-risk
	// calls of the agent's interrupt_on tools.
	AutoApprove bool `json:"auto_approve,omitempty"`
}

// memoryPayload tells the runtime which of the memory's models the admin has
// picked (Admin → Memory models): without the embedding model nothing is
// recalled by meaning, without the chat model nothing is learned from the
// turn. The agents' notes work either way.
type memoryPayload struct {
	Recall bool `json:"recall"`
	Learn  bool `json:"learn"`
}

// turnRequest asks the runtime to run (or resume) one turn.
type turnRequest struct {
	Token    string           `json:"token"`
	Gateway  string           `json:"gateway"`
	Agent    agentPayload     `json:"agent"`
	Turn     vmm.AgentTurn    `json:"turn"`
	Decision *decisionPayload `json:"decision,omitempty"`
	Memory   memoryPayload    `json:"memory"`
	// Timeline: the space's timeline is served to the turn as a built-in MCP
	// server ({gateway}/timeline/mcp).
	Timeline bool `json:"timeline"`
	// CodeMode: capability calling (apps, platform tools, timeline) goes
	// through Cloudflare Code Mode search/execute ({gateway}/codemode/mcp)
	// instead of one LLM tool per function.
	CodeMode bool `json:"codemode"`
	// OpenCode: the node's programmer switch. On, OpenCode builds apps and
	// does the coding (agents brief it); off, the agents build and code
	// themselves. Independent of AgentEngine.
	OpenCode bool `json:"opencode"`
	// AgentEngine is "deepagents" (LangGraph, platform LLM gateway),
	// "opencode" (headless OpenCode CLI, its own free models) or "deepseek"
	// (headless DeepSeek Harness with its own memory and swarm, on the
	// platform LLM gateway). Read for this turn, so an admin change is
	// already in effect.
	AgentEngine string `json:"agent_engine"`
}

// turnResult is what the runtime answers a turn with.
type turnResult struct {
	Answered bool   `json:"answered"`
	Reply    string `json:"reply"`
	// Status is "done", "awaiting" (the agent asked people something and its
	// thread waits for the answer) or "failed".
	Status string `json:"status"`
	Error  string `json:"error"`
}

// agentEngines are the engines the runtime can run a turn on.
var agentEngines = map[string]bool{"deepagents": true, "opencode": true, "deepseek": true}

// engine is the node's agentic engine for the next turn (deepagents when
// unknown or unread).
func (a *Adapter) engine(ctx context.Context) string {
	if a.platform != nil {
		if e, err := a.platform.AgentEngine(ctx); err == nil && agentEngines[e] {
			return e
		}
	}
	return "deepagents"
}

// open starts a turn: it checks the agent can work and mints the turn token.
func (a *Adapter) open(ctx context.Context, vmID string, turn vmm.AgentTurn) (*session, turnRequest, error) {
	def, err := a.agent(vmID)
	if err != nil {
		return nil, turnRequest{}, err
	}
	def.mu.Lock()
	status, spec := def.vm.Status, def.spec
	def.mu.Unlock()
	if status != vmm.StatusRunning {
		return nil, turnRequest{}, errs.New(errs.CodeUnavailable, "agent "+spec.Name+" is "+string(status))
	}
	account, err := identity.Parse(turn.Agent.AccountID)
	if err != nil {
		return nil, turnRequest{}, errs.InvalidArgument("turn has no agent account")
	}
	if turn.Agent.Name == "" {
		turn.Agent.Name = spec.Name
	}
	endRuntime := vmm.Trace(ctx, "runtime.ensure", "")
	err = a.ensureRuntime(ctx)
	endRuntime()
	if err != nil {
		return nil, turnRequest{}, err
	}
	// The engine is read first: an OpenCode turn must not resolve the platform
	// LLM, decision, memory or Code Mode resources at all.
	engine := a.engine(ctx)
	platformModels := engine == "deepagents" || engine == "deepseek"
	if platformModels && spec.ContextWindow == 0 && a.platform != nil {
		// The runtime summarizes the agent's history against the model's
		// window: tell it the window of the model the turn will really use.
		if provider, err := a.platform.ResolveChat(ctx, spec.Provider, spec.Model); err == nil && provider.ContextWindow > 0 {
			spec.ContextWindow = provider.ContextWindow
		}
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return nil, turnRequest{}, err
	}
	token := hex.EncodeToString(raw)
	base := context.WithoutCancel(ctx)
	if platformModels {
		// Sandbox OpenCode (and any other in-turn tool) reuses this credential so
		// its completions hit the same metered /llm proxy as the agent runtime.
		// The OpenCode engine uses its own free models, so it gets no such handle.
		base = vmm.WithTurnLLM(base, vmm.TurnLLM{
			Token:   token,
			BaseURL: a.nodeURL + gatewayPrefix + "/llm",
			Model:   "aseman/default",
		})
	}
	s := &session{
		token: token, def: def, account: account,
		botID: turn.Agent.BotID, spaceID: turn.SpaceID, roomID: turn.RoomID,
		base: base, started: time.Now(),
		sentMessages: map[string]bool{}, attachments: map[string]bool{},
	}
	for _, attachment := range turn.Attachments {
		s.attachments[attachment.ID] = true
	}
	a.mu.Lock()
	a.sessions[s.token] = s
	a.mu.Unlock()
	// Its project's memory work is charged to whoever runs its agents.
	a.memory.notePayer(turn.SpaceID, vmm.ExecutionFrom(ctx).ActorID)
	req := turnRequest{
		Token: s.token, Gateway: a.nodeURL + gatewayPrefix,
		Agent: agentPayload{Spec: spec, BotID: turn.Agent.BotID, AccountID: turn.Agent.AccountID, VMID: vmID},
		Turn:  turn,
		// Unknown or unread: the Deep Agents runtime, as before.
		AgentEngine: engine,
	}
	if a.platform != nil {
		// The programmer switch is independent of the engine; keep it truthful.
		on, err := a.platform.OpenCodeEnabled(ctx)
		req.OpenCode = err == nil && on
	}
	if engine == "deepseek" {
		// DeepSeek Harness brings its own memory and swarm (no OpenViking or
		// decision payloads); the space's timeline and Code Mode reach it
		// through its Aseman MCP bridge.
		if a.platform != nil {
			req.Timeline = a.timelineOn(ctx)
			req.CodeMode = true
		}
		return s, req, nil
	}
	if engine != "deepagents" {
		// OpenCode brings its own models and tools: no platform decision,
		// memory, timeline or Code Mode payloads cross the turn.
		return s, req, nil
	}
	if a.platform != nil {
		// Off or unusable, the turn runs as it always has.
		if decision, err := a.platform.ResolveDecision(ctx); err == nil {
			req.Decision = &decisionPayload{Enabled: true, Model: decision.Model, AutoApprove: decision.AutoApprove}
		}
		_, embedErr := a.platform.ResolveMemoryEmbedding(ctx)
		_, chatErr := a.platform.ResolveMemoryChat(ctx)
		req.Memory = memoryPayload{Recall: embedErr == nil, Learn: chatErr == nil}
		req.Timeline = a.timelineOn(ctx)
		// Code Mode is always on when the tools namespace is loaded: agents
		// call apps, platform tools and the timeline by writing JS against
		// one OpenAPI surface (search + execute).
		req.CodeMode = true
	}
	return s, req, nil
}

// close revokes a turn's token.
func (a *Adapter) close(s *session) {
	a.mu.Lock()
	delete(a.sessions, s.token)
	a.mu.Unlock()
}

func (a *Adapter) byToken(token string) *session {
	if token == "" {
		return nil
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.sessions[token]
}

// run sends one turn to the runtime and waits for its outcome. Cancelling
// ctx (the room turn was cancelled, the node shuts down) aborts the request,
// and the runtime cancels the agent's run.
func (a *Adapter) run(ctx context.Context, path string, req turnRequest) (turnResult, error) {
	var out turnResult
	status := vmm.StatusFrom(ctx)
	if status != nil {
		status(req.Turn.Agent.Name, "thinking…")
	}
	// From here the agent's runtime works: the gaps between its model calls and
	// tools in the trace are its own time (loading its thread, recalling memory,
	// thinking), the total is this span.
	endRun := vmm.Trace(ctx, "agent.run", req.Agent.Name)
	err := a.call(ctx, http.MethodPost, path, req, &out)
	endRun()
	if err != nil {
		return out, err
	}
	switch out.Status {
	case "failed":
		if out.Error == "" {
			out.Error = "the agent's run failed"
		}
		return out, errs.New(errs.CodeVMM, out.Error)
	case "cancelled":
		return out, errs.New(errs.CodeUnavailable, "the agent's run was cancelled")
	}
	return out, nil
}

// Prompt implements vmm.AgentRuntime: it runs a turn of the agent in the room
// and returns its reply. A turn that ends on a question returns the question;
// the agent's thread waits for the answer (see Reply).
func (a *Adapter) Prompt(ctx context.Context, vmID string, turn vmm.AgentTurn) (string, error) {
	s, req, err := a.open(ctx, vmID, turn)
	if err != nil {
		return "", err
	}
	defer a.close(s)
	out, err := a.run(ctx, "/v1/turns", req)
	s.settle(ctx)
	return strings.TrimSpace(out.Reply), err
}

// Observe implements vmm.AgentRuntime. The runtime reads the room through the
// messaging API at the start of every turn, so a message the agent was not
// asked to answer needs no delivery of its own.
func (a *Adapter) Observe(context.Context, string, vmm.AgentTurn) error { return nil }

// Reply implements vmm.AgentRuntime: a person's message answers the question
// the agent waits on in the room (turn.QuestionID, or its oldest there). The
// agent's thread resumes with the answer and what it says next is returned.
func (a *Adapter) Reply(ctx context.Context, vmID string, turn vmm.AgentTurn) (bool, string, error) {
	if !a.waiting(ctx, vmID, turn) {
		return false, "", nil
	}
	s, req, err := a.open(ctx, vmID, turn)
	if err != nil {
		return false, "", err
	}
	defer a.close(s)
	out, err := a.run(ctx, "/v1/answers", req)
	s.settle(ctx)
	if !out.Answered && err == nil {
		return false, "", nil
	}
	return true, strings.TrimSpace(out.Reply), err
}

// waiting reports whether the agent has an open question in the turn's room
// (matching turn.QuestionID when given), without starting a turn.
func (a *Adapter) waiting(ctx context.Context, vmID string, turn vmm.AgentTurn) bool {
	qs, err := a.Questions(ctx, vmID, turn.SpaceID)
	if err != nil {
		return false
	}
	for _, q := range qs {
		if q.RoomID != turn.RoomID && turn.QuestionID == "" {
			continue
		}
		if turn.QuestionID == "" || q.ID == turn.QuestionID {
			return true
		}
	}
	return false
}

// Questions implements vmm.QuestionLister: the questions the agent is
// waiting on in a space.
func (a *Adapter) Questions(ctx context.Context, vmID, spaceID string) ([]vmm.AgentQuestion, error) {
	def, err := a.agent(vmID)
	if err != nil {
		return nil, err
	}
	if a.runtimeURL == "" {
		a.runtimeMu.Lock()
		started := a.runtimeVM != "" || time.Since(a.healthyAt) < healthTTL
		a.runtimeMu.Unlock()
		if !started && !a.healthy(ctx) {
			return nil, nil // nothing has run yet, so nothing waits
		}
	}
	def.mu.Lock()
	name := def.spec.Name
	def.mu.Unlock()
	q := url.Values{"vm": {vmID}, "space": {spaceID}}
	var out struct {
		Questions []vmm.AgentQuestion `json:"questions"`
	}
	qctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err := a.call(qctx, http.MethodGet, "/v1/questions?"+q.Encode(), nil, &out); err != nil {
		return nil, err
	}
	for i := range out.Questions {
		if out.Questions[i].Agent == "" {
			out.Questions[i].Agent = name
		}
	}
	return out.Questions, nil
}

// ForgetRoom implements vmm.RoomForgetter: every agent's conversation of a
// room (a deleted room thread) is dropped from the runtime.
func (a *Adapter) ForgetRoom(ctx context.Context, spaceID, roomID string) error {
	if a.runtimeURL == "" {
		a.runtimeMu.Lock()
		started := a.runtimeVM != "" || time.Since(a.healthyAt) < healthTTL
		a.runtimeMu.Unlock()
		if !started && !a.healthy(ctx) {
			return nil // nothing has run yet, so nothing to forget
		}
	}
	fctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	return a.call(fctx, http.MethodPost, "/v1/rooms/forget", map[string]string{"space": spaceID, "room": roomID}, nil)
}

// agentName is the turn's agent as people know it.
func (s *session) agentName() string {
	if s.def == nil {
		return ""
	}
	s.def.mu.Lock()
	defer s.def.mu.Unlock()
	return s.def.spec.Name
}
