package deepagents

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/usage/models/usage"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
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
	// Working: the shared sandbox, tool and miniapp bots and platform tools.
	"spaces.ask": true, "spaces.tools_list": true,
	// The project's files, read without starting its computer.
	"spaces.sandbox_files": true,
	// Knowing the space and its people.
	"spaces.members_list": true, "spaces.bots_list": true, "spaces.room_get": true,
	"spaces.room_list": true, "spaces.file_get": true, "spaces.file_list": true,
	"users.account_get": true, "users.search": true,
	// The swarm: work logs, live status and recruiting specialists.
	"spaces.agent_log": true, "spaces.agent_recruit": true,
}

type route struct {
	method  network.Method
	path    string
	handler network.Handler
}

func routes(a *Adapter) []route {
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
	resp, err := a.k.Actions().Dispatch(scoped{Context: ctx, values: s.base}, in.Namespace, in.Action,
		&api.ActionRequest{Caller: api.Caller{ID: s.account, Kind: "bot"}, Body: in.Body})
	if err != nil {
		return errorResponse(err), nil
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
	s.def.mu.Lock()
	spec := s.def.spec
	s.def.mu.Unlock()
	if err := a.gate(s); err != nil {
		return openAIError(http.StatusPaymentRequired, err.Error()), nil
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
	callCtx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()
	up, err := providerRequest(callCtx, provider, "/chat/completions", body)
	if err != nil {
		return openAIError(500, err.Error()), nil
	}
	if stream {
		up.Header.Set("Accept", "text/event-stream")
	}
	resp, err := a.client.Do(up)
	if err != nil {
		return openAIError(502, "LLM provider unreachable: "+err.Error()), nil
	}
	defer resp.Body.Close()
	var data []byte
	if tools, _ := body["tools"].([]any); stream && resp.StatusCode < 300 && len(tools) > 0 {
		// A step of the agent's own loop (its other model calls, such as
		// summarizing, carry no tools): show the answer as it is written.
		data, err = a.followStream(s, spec.Name, resp.Body)
	} else {
		data, err = io.ReadAll(resp.Body)
	}
	if err != nil {
		return openAIError(502, "LLM provider response failed: "+err.Error()), nil
	}
	if resp.StatusCode < 300 {
		in, out := parseUsage(data, stream)
		a.meter(s, in, out)
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
	return jsonResponse(200, map[string]any{"object": "list", "data": []map[string]any{
		{"id": model, "object": "model", "owned_by": "tradera"},
	}}), nil
}

// draftEvery is the shortest time between two published versions of an answer
// in progress: often enough to read as typing, rare enough to stay cheap.
const draftEvery = 150 * time.Millisecond

// followStream reads a streamed model response to its end (the runtime gets
// it whole, as before) and publishes the text as it arrives as the agent's
// draft in the room. A response that turns out to call a tool is a step, not
// an answer: its draft is withdrawn.
func (a *Adapter) followStream(s *session, agent string, body io.Reader) ([]byte, error) {
	roomID, rerr := identity.Parse(s.roomID)
	publish := func(text string) {
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
	)
	for {
		line, err := reader.ReadBytes('\n')
		all.Write(line)
		if payload, ok := bytes.CutPrefix(bytes.TrimSpace(line), []byte("data:")); ok && !toolCall {
			var chunk struct {
				Choices []struct {
					Delta struct {
						Content   any   `json:"content"`
						ToolCalls []any `json:"tool_calls"`
					} `json:"delta"`
				} `json:"choices"`
			}
			if json.Unmarshal(bytes.TrimSpace(payload), &chunk) == nil && len(chunk.Choices) > 0 {
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
			return all.Bytes(), err
		}
	}
	if !toolCall && text.Len() > 0 {
		publish(text.String())
	}
	return all.Bytes(), nil
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
	return jsonResponse(status, map[string]any{"error": map[string]any{"message": msg, "type": "tradera_error"}})
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
