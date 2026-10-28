package deepagents

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/actions/usage/models/usage"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// gatewayPrefix is where the runtime reaches the node during a turn.
const gatewayPrefix = "/deepagents/v1"

// allowedActions is the platform surface an agent works through. Everything
// an agent does is one of these actions, dispatched as the agent's account
// with the same authorization people get.
var allowedActions = map[string]bool{
	// Talking: rooms (people ↔ agents, lead ↔ the agents it delegates to) and
	// direct messages.
	"spaces.message_send": true, "spaces.message_list": true, "spaces.message_search": true,
	"users.dm_send": true, "users.dm_list": true,
	// Working: the shared sandbox, app bots and platform tools.
	"spaces.ask": true, "spaces.tools_list": true,
	// The project's files, read without starting its computer.
	"spaces.sandbox_files": true,
	// Knowing the space and its people.
	"spaces.members_list": true, "spaces.bots_list": true, "spaces.room_get": true,
	"spaces.room_list": true, "spaces.file_get": true, "spaces.file_list": true,
	"users.account_get": true, "users.search": true,
	// The swarm: work logs, live status, recruiting specialists and hiring
	// published agents from the marketplace.
	"spaces.agent_log": true, "spaces.agent_recruit": true, "spaces.agent_hire": true,
	"market.catalog": true,
}

type route struct {
	method  network.Method
	path    string
	handler network.Handler
}

func routes(a *Adapter) []route {
	out := baseRoutes(a)
	for i := range out {
		out[i].handler = a.withWorkload(out[i].handler)
	}
	return out
}

func baseRoutes(a *Adapter) []route {
	return []route{
		{network.MethodPost, gatewayPrefix + "/call", a.serveCall},
		{network.MethodPost, gatewayPrefix + "/llm/chat/completions", a.serveChat},
		{network.MethodGet, gatewayPrefix + "/llm/models", a.serveModels},
		{network.MethodPost, gatewayPrefix + "/decision/evaluate", a.serveDecision},
		// The models of the agents' memory server (OpenViking), not of a turn.
		{network.MethodPost, gatewayPrefix + "/memory/chat/completions", a.serveMemoryChat},
		{network.MethodPost, gatewayPrefix + "/memory/embeddings", a.serveMemoryEmbeddings},
		// The space's timeline, as a built-in MCP server (timeline.go).
		{network.MethodPost, gatewayPrefix + "/timeline/mcp", a.serveTimeline},
		// Cloudflare Code Mode: search/execute over the space's apps (codemode.go).
		{network.MethodPost, gatewayPrefix + "/codemode/mcp", a.serveCodeMode},
		// The agents' learning: their playbook improving between turns (learn.go).
		{network.MethodPost, gatewayPrefix + "/learn/chat/completions", a.serveLearn},
		{network.MethodPost, gatewayPrefix + "/learn/decision/evaluate", a.serveLearnDecision},
	}
}

// platform is what the adapter needs from other namespaces, through the
// namespace bridge so it never depends on another module's service.
type platform interface {
	ResolveChat(ctx context.Context, provider, model string) (vmm.ProviderConfig, error)
	// ResolveDecision is the node's decision model; an error means it is off.
	ResolveDecision(ctx context.Context) (vmm.ProviderConfig, error)
	// ResolveMemoryChat / ResolveMemoryEmbedding are the models of the agents'
	// memory; an error means the admin has not picked (a usable) one.
	ResolveMemoryChat(ctx context.Context) (vmm.ProviderConfig, error)
	ResolveMemoryEmbedding(ctx context.Context) (vmm.ProviderConfig, error)
	// TimelineEnabled / TimelineMCP are the spaces' timelines; an error from
	// TimelineEnabled means the timeline namespace is not loaded.
	TimelineEnabled(ctx context.Context) (bool, error)
	TimelineMCP(ctx context.Context, spaceID string, body []byte) ([]byte, error)
	// CodeModeMCP is Cloudflare Code Mode over the space's connected apps.
	CodeModeMCP(ctx context.Context, spaceID string, body []byte) ([]byte, error)
	// OpenCodeEnabled is the node's OpenCode switch (Admin → OpenCode): on,
	// OpenCode builds apps and writes code; off, the agents do it themselves.
	OpenCodeEnabled(ctx context.Context) (bool, error)
}

type kernelPlatform struct{ K api.Kernel }

func (p kernelPlatform) ResolveChat(ctx context.Context, provider, model string) (vmm.ProviderConfig, error) {
	var out vmm.ProviderConfig
	err := bridge.Invoke(ctx, p.K, "llm", "ResolveChat", []any{ctx, provider, model}, &out)
	return out, err
}

func (p kernelPlatform) ResolveDecision(ctx context.Context) (vmm.ProviderConfig, error) {
	var out vmm.ProviderConfig
	err := bridge.Invoke(ctx, p.K, "llm", "ResolveDecision", []any{ctx}, &out)
	return out, err
}

func (p kernelPlatform) ResolveMemoryChat(ctx context.Context) (vmm.ProviderConfig, error) {
	var out vmm.ProviderConfig
	err := bridge.Invoke(ctx, p.K, "llm", "ResolveMemoryChat", []any{ctx}, &out)
	return out, err
}

func (p kernelPlatform) ResolveMemoryEmbedding(ctx context.Context) (vmm.ProviderConfig, error) {
	var out vmm.ProviderConfig
	err := bridge.Invoke(ctx, p.K, "llm", "ResolveMemoryEmbedding", []any{ctx}, &out)
	return out, err
}

// scoped carries a turn's values (execution scope, status hook, usage meter)
// under a request's deadline and cancellation.
type scoped struct {
	context.Context
	values context.Context
}

func (c scoped) Value(key any) any { return c.values.Value(key) }

// serveCall dispatches one platform action for a turn:
// {"namespace","action","body"} → the action's own JSON response.
func (a *Adapter) serveCall(ctx context.Context, req *network.Request) (*network.Response, error) {
	s := a.byToken(bearer(req.Header))
	if s == nil {
		return errorResponse(errs.Unauthenticated("invalid or expired agent turn token")), nil
	}
	defer s.begin()()
	var in struct {
		Namespace string          `json:"namespace"`
		Action    string          `json:"action"`
		Body      json.RawMessage `json:"body"`
	}
	if err := json.Unmarshal(req.Body, &in); err != nil {
		return errorResponse(errs.InvalidArgument("invalid call")), nil
	}
	name := in.Namespace + "." + in.Action
	if !allowedActions[name] {
		return errorResponse(errs.Permission(name + " is not part of the agent platform API")), nil
	}
	if len(in.Body) == 0 {
		in.Body = json.RawMessage("{}")
	}
	if err := s.checkRequestMode(name, in.Body); err != nil {
		return errorResponse(err), nil
	}
	// An agent works inside the space of its turn.
	var scope struct {
		Space string `json:"space"`
	}
	if json.Unmarshal(in.Body, &scope) == nil && scope.Space != "" && scope.Space != s.spaceID {
		return errorResponse(errs.Permission("an agent acts only inside the space of its turn")), nil
	}
	// Every action is decided and recorded before it runs, and runs with the
	// person's secrets put in; what comes back hides them again.
	call := scoped{Context: ctx, values: s.base}
	body, decision, err := a.govern(call, s, name, in.Body)
	if err != nil {
		return errorResponse(err), nil
	}
	endCall := vmm.Trace(s.base, "platform."+name, "")
	resp, err := a.k.Actions().Dispatch(call, in.Namespace, in.Action,
		&api.ActionRequest{Caller: api.Caller{ID: s.account, Kind: "bot"}, Body: body})
	endCall()
	if err != nil {
		gate.Finish(call, a.k, decision, "", err)
		return errorResponse(err), nil
	}
	if out := gate.Finish(call, a.k, decision, string(resp.Body), nil); out != string(resp.Body) {
		resp.Body = []byte(out)
	}
	if name == "spaces.message_send" {
		var sent struct {
			MessageID string `json:"message_id"`
		}
		if json.Unmarshal(resp.Body, &sent) == nil && sent.MessageID != "" {
			s.mu.Lock()
			if s.sentMessages == nil {
				s.sentMessages = map[string]bool{}
			}
			s.sentMessages[sent.MessageID] = true
			s.mu.Unlock()
		}
	}
	status := resp.Status
	if status == 0 {
		status = http.StatusOK
	}
	return &network.Response{Status: status, Header: map[string]string{"Content-Type": "application/json"}, Body: resp.Body}, nil
}

// govern decides a platform action of the turn's agent. A sandbox command is
// run as the gate returns it (secrets put in, shell-quoted).
func (a *Adapter) govern(ctx context.Context, s *session, name string, body json.RawMessage) (json.RawMessage, gate.Result, error) {
	res, err := gate.Check(ctx, a.k, gate.Request{Kind: gate.KindPlatform, Tool: name, Args: body, SpaceID: s.spaceID, RoomID: s.roomID,
		AgentID: s.botID, AgentName: s.agentName(), AgentAccount: s.account.String()})
	if err != nil {
		return nil, res, err
	}
	out := body
	if len(res.Args) > 0 {
		out = res.Args
	}
	if name == "spaces.ask" && res.Command != "" {
		var m map[string]any
		if json.Unmarshal(out, &m) == nil {
			m["body"] = res.Command
			if raw, err := json.Marshal(m); err == nil {
				out = raw
			}
		}
	}
	return out, res, nil
}

func (s *session) checkRequestMode(name string, body json.RawMessage) error {
	policy := vmm.ExecutionFrom(s.base)
	if !policy.NoMemory {
		return nil
	}
	switch name {
	case "spaces.message_list":
		var query struct {
			ReplyTo string `json:"reply_to"`
		}
		_ = json.Unmarshal(body, &query)
		s.mu.Lock()
		allowed := query.ReplyTo != "" && s.sentMessages[query.ReplyTo]
		s.mu.Unlock()
		if allowed {
			return nil
		}
	case "spaces.message_search", "users.dm_list", "spaces.room_get", "spaces.room_list", "spaces.file_list":
	case "spaces.file_get":
		var query struct {
			File string `json:"file"`
		}
		_ = json.Unmarshal(body, &query)
		if s.attachments[query.File] {
			return nil
		}
	case "spaces.ask":
		var query struct {
			Tool string `json:"tool"`
			Args struct {
				ID   string `json:"file_id"`
				URL  string `json:"url"`
				Path string `json:"path"`
			} `json:"args"`
		}
		_ = json.Unmarshal(body, &query)
		if query.Tool != "file_read" && query.Tool != "room_info" {
			return nil
		}
		if query.Args.ID == "" && query.Args.URL != "" {
			query.Args.ID = strings.TrimSuffix(strings.TrimPrefix(query.Args.URL, "/v1/files/"), "/content")
		}
		if query.Tool == "file_read" && query.Args.Path == "" && s.attachments[query.Args.ID] {
			return nil
		}
	default:
		return nil
	}
	return errs.Permission("space and room memory is disabled for this request")
}

// serveChat is the OpenAI-compatible model endpoint of a turn. It forwards to
// the agent's admin-configured provider with the provider key (which never
// leaves the node) and meters the tokens onto the turn.
func (a *Adapter) serveChat(ctx context.Context, req *network.Request) (*network.Response, error) {
	s := a.byToken(bearer(req.Header))
	if s == nil {
		return openAIError(401, "invalid or expired agent turn token"), nil
	}
	defer s.begin()()
	s.def.mu.Lock()
	spec := s.def.spec
	s.def.mu.Unlock()
	endGate := vmm.Trace(s.base, "llm.gate", "")
	gateErr := a.gate(s)
	endGate()
	if gateErr != nil {
		return openAIError(http.StatusPaymentRequired, gateErr.Error()), nil
	}
	provider, err := a.platform.ResolveChat(s.base, spec.Provider, spec.Model)
	if err != nil {
		return openAIError(503, "no LLM provider for this agent: "+err.Error()), nil
	}
	var body map[string]any
	if err := json.Unmarshal(req.Body, &body); err != nil {
		return openAIError(400, "invalid request body"), nil
	}
	stream, _ := body["stream"].(bool)
	if stream {
		opts, _ := body["stream_options"].(map[string]any)
		if opts == nil {
			opts = map[string]any{}
		}
		opts["include_usage"] = true
		body["stream_options"] = opts
	}
	callTimeout := a.llmCallTimeout
	if callTimeout <= 0 {
		callTimeout = defaultLLMCallTimeout
	}
	firstTimeout := a.llmFirstEventTimeout
	if firstTimeout <= 0 {
		firstTimeout = defaultLLMFirstEventTimeout
	}
	idleTimeout := a.llmStreamIdleTimeout
	if idleTimeout <= 0 {
		idleTimeout = defaultLLMStreamIdleTimeout
	}
	callCtx, cancelCall := context.WithTimeout(ctx, callTimeout)
	defer cancelCall()
	requestCtx, cancelRequest := context.WithCancel(callCtx)
	defer cancelRequest()
	up, err := providerRequest(requestCtx, provider, "/chat/completions", body)
	if err != nil {
		return openAIError(500, err.Error()), nil
	}
	if stream {
		up.Header.Set("Accept", "text/event-stream")
	}
	// Record every exit, including a cancelled or timed-out response. Without the
	// defer, precisely the calls admins need to diagnose disappeared from a run.
	llmStart := time.Now()
	traceDetail := provider.Model + " · interrupted"
	defer func() { vmm.TraceFrom(s.base, "llm.call", traceDetail, llmStart) }()
	firstDeadline := llmStart.Add(firstTimeout)
	type providerResult struct {
		resp *http.Response
		err  error
	}
	started := make(chan providerResult, 1)
	go func() {
		resp, callErr := a.client.Do(up)
		started <- providerResult{resp: resp, err: callErr}
	}()
	var resp *http.Response
	firstTimer := time.NewTimer(firstTimeout)
	select {
	case got := <-started:
		if !firstTimer.Stop() {
			select {
			case <-firstTimer.C:
			default:
			}
		}
		resp, err = got.resp, got.err
	case <-firstTimer.C:
		cancelRequest()
		go func() {
			if late := <-started; late.resp != nil {
				_ = late.resp.Body.Close()
			}
		}()
		traceDetail = fmt.Sprintf("%s · no response within %s", provider.Model, firstTimeout)
		return openAIError(http.StatusGatewayTimeout, "LLM provider did not start responding within "+firstTimeout.String()), nil
	case <-ctx.Done():
		if !firstTimer.Stop() {
			select {
			case <-firstTimer.C:
			default:
			}
		}
		cancelRequest()
		go func() {
			if late := <-started; late.resp != nil {
				_ = late.resp.Body.Close()
			}
		}()
		// The request reached the provider, which bills its input whether or
		// not anyone waits for the answer.
		in := estimateInputTokens(body)
		a.meter(s, in, 0)
		traceDetail = fmt.Sprintf("%s · cancelled before response · ≈%d in (estimated)", provider.Model, in)
		return openAIError(499, "LLM request cancelled"), nil
	}
	if err != nil {
		status := http.StatusBadGateway
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(callCtx.Err(), context.DeadlineExceeded) {
			status = http.StatusGatewayTimeout
		}
		traceDetail = provider.Model + " · provider unreachable: " + clip(err.Error(), 160)
		return openAIError(status, "LLM provider unreachable: "+err.Error()), nil
	}
	defer resp.Body.Close()
	firstEvent := time.Since(llmStart) // response headers for a non-streamed error
	var data []byte
	if stream && resp.StatusCode < 300 {
		// Every successful stream uses the SSE reader, including summarization
		// calls that carry no tools. Only an agent-loop call publishes a draft.
		tools, _ := body["tools"].([]any)
		remaining := time.Until(firstDeadline)
		if remaining <= 0 {
			cancelRequest()
			traceDetail = fmt.Sprintf("%s · no first event within %s", provider.Model, firstTimeout)
			return openAIError(http.StatusGatewayTimeout, "LLM provider did not send its first event within "+firstTimeout.String()), nil
		}
		beforeStream := time.Since(llmStart)
		var stats streamStats
		data, stats, err = a.followStream(callCtx, s, spec.Name, resp.Body, len(tools) > 0, remaining, idleTimeout)
		if stats.firstEvent > 0 {
			firstEvent = beforeStream + stats.firstEvent
		}
	} else {
		data, err = io.ReadAll(resp.Body)
	}
	if err != nil {
		status := http.StatusBadGateway
		if errors.Is(err, context.DeadlineExceeded) || isStreamTimeout(err) {
			status = http.StatusGatewayTimeout
		}
		// A response cut off (the turn stopped, or the stream broke) was still
		// produced and billed by the provider up to there: meter it.
		in, out, estimated := partialUsage(body, data, stream)
		a.meter(s, in, out)
		traceDetail = provider.Model + " · response failed: " + clip(err.Error(), 160) + meteredNote(in, out, estimated)
		return openAIError(status, "LLM provider response failed: "+err.Error()), nil
	}
	if resp.StatusCode < 300 {
		in, out := parseUsage(data, stream)
		a.meter(s, in, out)
		traceDetail = fmt.Sprintf("%s · first event %dms · %d in / %d out", provider.Model, firstEvent.Milliseconds(), in, out)
	} else {
		traceDetail = fmt.Sprintf("%s · HTTP %d", provider.Model, resp.StatusCode)
	}
	if msg, ok := contextOverflow(resp.StatusCode, data); ok {
		// Providers word (and code) a request larger than the model's window
		// in many ways; the runtime recovers from it (it summarizes and
		// retries) only when it recognizes it, so it gets OpenAI's form.
		return jsonResponse(http.StatusBadRequest, map[string]any{"error": map[string]any{
			"message": "context_length_exceeded: " + msg, "type": "invalid_request_error", "code": "context_length_exceeded",
		}}), nil
	}
	ct := resp.Header.Get("Content-Type")
	if ct == "" {
		ct = "application/json"
	}
	return &network.Response{Status: resp.StatusCode, Header: map[string]string{"Content-Type": ct}, Body: data}, nil
}

// providerRequest is a request to one of a provider's OpenAI-compatible
// endpoints (path: "/chat/completions", "/embeddings") for its model, with the
// provider's key, which never leaves the node.
func providerRequest(ctx context.Context, provider vmm.ProviderConfig, path string, body map[string]any) (*http.Request, error) {
	isVertex := provider.Kind == "vertex" || strings.Contains(provider.BaseURL, "aiplatform.googleapis.com")
	google := isVertex || provider.Kind == "gemini" || strings.Contains(provider.BaseURL, "googleapis.com")
	modelID := provider.Model
	if isVertex && !strings.Contains(modelID, "/") {
		modelID = "google/" + modelID
	}
	body["model"] = modelID
	if google {
		fillThoughtSignatures(body)
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	baseURL := provider.BaseURL
	if isVertex && strings.Contains(baseURL, "{location}") {
		baseURL = strings.ReplaceAll(baseURL, "{location}", "us-central1")
	}
	up, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(baseURL, "/")+path, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	up.Header.Set("Content-Type", "application/json")
	if provider.APIKey != "" {
		if google && !strings.HasPrefix(provider.APIKey, "ya29.") {
			up.Header.Set("X-Goog-Api-Key", provider.APIKey)
		} else {
			up.Header.Set("Authorization", "Bearer "+provider.APIKey)
		}
	}
	return up, nil
}

// overflowMarkers are how providers say a request exceeds the model's window.
var overflowMarkers = []string{
	"context_length_exceeded", "context length", "context window", "context limit", "maximum context",
	"prompt is too long", "input is too long", "too many input tokens", "input token count",
	"maximum number of tokens allowed", "reduce the length of the messages",
}

// contextOverflow reports whether a provider response refuses the request as
// larger than the model's window: an error response, or an error event in a
// stream that was accepted. Rate limits that mention tokens are not that.
func contextOverflow(status int, data []byte) (string, bool) {
	var texts []string
	if status >= 300 {
		texts = append(texts, string(data))
	} else {
		for _, line := range strings.Split(string(data), "\n") {
			payload, ok := strings.CutPrefix(strings.TrimSpace(line), "data:")
			if !ok || !strings.Contains(payload, `"error"`) {
				continue
			}
			var event struct {
				Error json.RawMessage `json:"error"`
			}
			if json.Unmarshal([]byte(strings.TrimSpace(payload)), &event) == nil && len(event.Error) > 0 {
				texts = append(texts, string(event.Error))
			}
		}
	}
	for _, text := range texts {
		lower := strings.ToLower(text)
		if strings.Contains(lower, "rate limit") || strings.Contains(lower, "per min") {
			continue
		}
		for _, marker := range overflowMarkers {
			if strings.Contains(lower, marker) {
				return clip(strings.TrimSpace(text), 500), true
			}
		}
	}
	return "", false
}

func (a *Adapter) serveModels(ctx context.Context, req *network.Request) (*network.Response, error) {
	s := a.byToken(bearer(req.Header))
	if s == nil {
		return openAIError(401, "invalid or expired agent turn token"), nil
	}
	s.def.mu.Lock()
	model := s.def.spec.Model
	s.def.mu.Unlock()
	if model == "" {
		model = "default"
	}
	// Include stable aliases OpenCode (and other OpenAI clients) select as
	// aseman/default; serveChat still rewrites to the agent's provider model.
	return jsonResponse(200, map[string]any{"object": "list", "data": []map[string]any{
		{"id": model, "object": "model", "owned_by": "aseman"},
		{"id": "default", "object": "model", "owned_by": "aseman"},
		{"id": "aseman/default", "object": "model", "owned_by": "aseman"},
	}}), nil
}

// draftEvery is the shortest time between two published versions of an answer
// in progress: often enough to read as typing, rare enough to stay cheap.
const draftEvery = 150 * time.Millisecond

type streamStats struct {
	firstEvent time.Duration
	done       bool
}

type streamTimeoutError struct {
	phase string
	wait  time.Duration
}

func (e *streamTimeoutError) Error() string {
	return fmt.Sprintf("provider stream %s timeout after %s", e.phase, e.wait)
}

func isStreamTimeout(err error) bool {
	var target *streamTimeoutError
	return errors.As(err, &target)
}

type streamRead struct {
	line []byte
	err  error
}

// readStreamLine gives each read a liveness deadline. Closing an HTTP response
// body unblocks its pending read; the buffered result channel also prevents a
// badly behaved test/provider reader from stranding the reader goroutine.
func readStreamLine(ctx context.Context, body io.ReadCloser, reader *bufio.Reader, wait time.Duration, phase string) ([]byte, error) {
	result := make(chan streamRead, 1)
	go func() {
		line, err := reader.ReadBytes('\n')
		result <- streamRead{line: line, err: err}
	}()
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case got := <-result:
		return got.line, got.err
	case <-ctx.Done():
		_ = body.Close()
		return nil, ctx.Err()
	case <-timer.C:
		_ = body.Close()
		return nil, &streamTimeoutError{phase: phase, wait: wait}
	}
}

// followStream reads an OpenAI-compatible SSE response until its protocol
// terminator, not until the peer happens to close its HTTP connection. It also
// enforces a deadline for the first event and for every later event. Agent-loop
// calls publish text as a room draft; internal model calls only consume it.
func (a *Adapter) followStream(ctx context.Context, s *session, agent string, body io.ReadCloser, publishDraft bool,
	firstTimeout, idleTimeout time.Duration) ([]byte, streamStats, error) {
	roomID, rerr := identity.Parse(s.roomID)
	publish := func(text string) {
		if !publishDraft {
			return
		}
		if a.draftFn != nil {
			a.draftFn(s.roomID, agent, text)
			return
		}
		if a.k == nil || rerr != nil {
			return
		}
		_ = bridge.Invoke(s.base, a.k, "spaces", "SetRoomDraft", []any{s.base, roomID, agent, text})
	}
	var (
		all      bytes.Buffer
		text     strings.Builder
		toolCall bool
		sent     time.Time
		reader   = bufio.NewReader(body)
		stats    streamStats
		started  = time.Now()
	)
	for {
		wait, phase := idleTimeout, "idle"
		if stats.firstEvent == 0 {
			wait, phase = firstTimeout, "first event"
		}
		line, err := readStreamLine(ctx, body, reader, wait, phase)
		if stats.firstEvent == 0 && len(line) > 0 {
			stats.firstEvent = time.Since(started)
		}
		all.Write(line)
		payload, event := bytes.CutPrefix(bytes.TrimSpace(line), []byte("data:"))
		payload = bytes.TrimSpace(payload)
		if event && bytes.Equal(payload, []byte("[DONE]")) {
			// The SSE protocol is complete even if an intermediary keeps the HTTP
			// connection alive. Preserve anything already buffered (normally the
			// blank event separator) without performing another blocking read.
			if buffered := reader.Buffered(); buffered > 0 {
				if tail, peekErr := reader.Peek(buffered); peekErr == nil {
					all.Write(tail)
					_, _ = reader.Discard(buffered)
				}
			}
			stats.done = true
			break
		}
		if event && !toolCall {
			var chunk struct {
				Choices []struct {
					Delta struct {
						Content   any   `json:"content"`
						ToolCalls []any `json:"tool_calls"`
					} `json:"delta"`
				} `json:"choices"`
			}
			if json.Unmarshal(payload, &chunk) == nil && len(chunk.Choices) > 0 {
				delta := chunk.Choices[0].Delta
				if len(delta.ToolCalls) > 0 {
					toolCall = true
					publish("")
				} else if piece, _ := delta.Content.(string); piece != "" {
					text.WriteString(piece)
					if time.Since(sent) >= draftEvery {
						sent = time.Now()
						publish(text.String())
					}
				}
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			publish("")
			return all.Bytes(), stats, err
		}
	}
	if !toolCall && text.Len() > 0 {
		publish(text.String())
	}
	return all.Bytes(), stats, nil
}

// meter records the tokens of one model call on the agent and on its turn.
func (a *Adapter) meter(s *session, in, out int64) {
	if in == 0 && out == 0 {
		return
	}
	s.def.mu.Lock()
	s.def.tokensIn += in
	s.def.tokensOut += out
	s.def.mu.Unlock()
	s.mu.Lock()
	s.tokIn += in
	s.tokOut += out
	s.mu.Unlock()
	vmm.AddInvocationUsage(s.base, usage.Delta{TokensIn: in, TokensOut: out})
	vmm.BudgetFrom(s.base).RecordTokens(in, out)
}

// gate stops a turn that can no longer pay: before each model call the node
// checks the payer's wallet and the project's budget against everything the
// turn has used so far.
func (a *Adapter) gate(s *session) error {
	if a.k == nil {
		return nil
	}
	payer, err := identity.Parse(vmm.ExecutionFrom(s.base).ActorID)
	if err != nil {
		return nil // no one to bill: not a metered run
	}
	botID, err := identity.Parse(s.botID)
	if err != nil {
		return nil
	}
	s.mu.Lock()
	in, out := s.tokIn, s.tokOut
	s.mu.Unlock()
	seconds := int64(time.Since(s.started).Seconds())
	if a.gateFn != nil {
		return a.gateFn(s.base, payer, botID, seconds, in, out)
	}
	return bridge.Invoke(s.base, a.k, "bots", "GateRun", []any{s.base, payer, botID, seconds, in, out})
}

// parseUsage reads token usage from a chat completion (or the final chunk of
// a stream).
// estimateInputTokens is a request's input size when the provider never
// reported it: about 4 characters a token over its messages and tools, which is
// what providers bill.
func estimateInputTokens(body map[string]any) int64 {
	n := 0
	for _, key := range []string{"messages", "tools"} {
		if v, ok := body[key]; ok {
			b, _ := json.Marshal(v)
			n += len(b)
		}
	}
	return int64(n/4) + 1
}

// streamedChars counts what a stream wrote: its text and its tool-call
// arguments.
func streamedChars(data []byte) int {
	n := 0
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "data:"))
		if line == "" || line == "[DONE]" {
			continue
		}
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content   string `json:"content"`
					ToolCalls []struct {
						Function struct {
							Name      string `json:"name"`
							Arguments string `json:"arguments"`
						} `json:"function"`
					} `json:"tool_calls"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if json.Unmarshal([]byte(line), &chunk) != nil {
			continue
		}
		for _, c := range chunk.Choices {
			n += len(c.Delta.Content)
			for _, t := range c.Delta.ToolCalls {
				n += len(t.Function.Name) + len(t.Function.Arguments)
			}
		}
	}
	return n
}

// partialUsage is what an interrupted call used: the provider's own report
// when it arrived, else an estimate (the input from the request, the output
// from what was streamed). estimated says which.
func partialUsage(body map[string]any, data []byte, stream bool) (in, out int64, estimated bool) {
	if in, out = parseUsage(data, stream); in > 0 || out > 0 {
		return in, out, false
	}
	in = estimateInputTokens(body)
	if stream {
		if chars := streamedChars(data); chars > 0 {
			out = int64(chars/4) + 1
		}
	}
	return in, out, true
}

func meteredNote(in, out int64, estimated bool) string {
	if in == 0 && out == 0 {
		return ""
	}
	if estimated {
		return fmt.Sprintf(" · ≈%d in / %d out (estimated)", in, out)
	}
	return fmt.Sprintf(" · %d in / %d out", in, out)
}

func parseUsage(data []byte, stream bool) (int64, int64) {
	type u struct {
		Usage *struct {
			PromptTokens     int64 `json:"prompt_tokens"`
			CompletionTokens int64 `json:"completion_tokens"`
		} `json:"usage"`
	}
	if !stream {
		var v u
		if json.Unmarshal(data, &v) == nil && v.Usage != nil {
			return v.Usage.PromptTokens, v.Usage.CompletionTokens
		}
		return 0, 0
	}
	var in, out int64
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "data:"))
		if line == "" || line == "[DONE]" {
			continue
		}
		var v u
		if json.Unmarshal([]byte(line), &v) == nil && v.Usage != nil {
			in, out = v.Usage.PromptTokens, v.Usage.CompletionTokens
		}
	}
	return in, out
}

func bearer(h map[string]string) string {
	for k, v := range h {
		if strings.EqualFold(k, "Authorization") {
			return strings.TrimSpace(strings.TrimPrefix(v, "Bearer "))
		}
	}
	return ""
}

func jsonResponse(status int, v any) *network.Response {
	b, _ := json.Marshal(v)
	return &network.Response{Status: status, Header: map[string]string{"Content-Type": "application/json"}, Body: b}
}

func errorResponse(err error) *network.Response {
	status := http.StatusInternalServerError
	switch errs.CodeOf(err) {
	case errs.CodeNotFound:
		status = http.StatusNotFound
	case errs.CodeAlreadyExists, errs.CodeConflict:
		status = http.StatusConflict
	case errs.CodeInvalidArgument:
		status = http.StatusBadRequest
	case errs.CodeUnauthenticated:
		status = http.StatusUnauthorized
	case errs.CodePermission:
		status = http.StatusForbidden
	}
	return jsonResponse(status, map[string]any{"code": string(errs.CodeOf(err)), "error": err.Error()})
}

func openAIError(status int, msg string) *network.Response {
	return jsonResponse(status, map[string]any{"error": map[string]any{"message": msg, "type": "aseman_error"}})
}

// skipThoughtSignature is Google's documented placeholder for a tool call whose
// real thought signature was not kept.
const skipThoughtSignature = "skip_thought_signature_validator"

// fillThoughtSignatures makes a conversation acceptable to Gemini 3 models.
// They sign each tool call and reject a later request that replays the call
// without that signature, but the OpenAI client the agent runtime uses drops the
// signature (extra_content) it does not know. Calls without one get Google's
// skip value; real signatures that survive are left alone.
func fillThoughtSignatures(body map[string]any) {
	msgs, _ := body["messages"].([]any)
	for _, m := range msgs {
		msg, _ := m.(map[string]any)
		calls, _ := msg["tool_calls"].([]any)
		for _, c := range calls {
			call, _ := c.(map[string]any)
			if call == nil {
				continue
			}
			extra, _ := call["extra_content"].(map[string]any)
			google, _ := extra["google"].(map[string]any)
			if s, _ := google["thought_signature"].(string); s != "" {
				continue
			}
			call["extra_content"] = map[string]any{"google": map[string]any{"thought_signature": skipThoughtSignature}}
		}
	}
}
