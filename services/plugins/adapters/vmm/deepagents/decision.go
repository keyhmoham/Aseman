package deepagents

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/tradera/tradera/plugins/actions/usage/models/usage"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// decisionTimeout bounds one decision: the runtime falls back to the agent's
// own model rather than wait on a slow decision provider.
const decisionTimeout = 10 * time.Second

// maxDecisionQuestions bounds one evaluate request (one question per tool).
const maxDecisionQuestions = 300

// serveDecision is the turn's decision endpoint: typed questions about the
// turn's state answered by the node's decision model (TypeSafe AI's Jev, or
// any model of the decision API) with probabilities. It forwards to the admin's
// decision provider with the provider key, which never leaves the node, and
// meters the cost onto the turn at the decision model's own prices.
//
//	POST {gateway}/decision/evaluate {"state": any, "questions": {...}}
//	→ {"model", "answers": {...}, "usage": {...}}
//
// 409 decision_disabled means the decision model is off (or unusable): the
// runtime then decides with the agent's own model.
func (a *Adapter) serveDecision(ctx context.Context, req *network.Request) (*network.Response, error) {
	s := a.byToken(bearer(req.Header))
	if s == nil {
		return openAIError(401, "invalid or expired agent turn token"), nil
	}
	defer s.begin()()
	defer vmm.Trace(s.base, "decision", "")()
	if err := a.gate(s); err != nil {
		return openAIError(http.StatusPaymentRequired, err.Error()), nil
	}
	provider, err := a.platform.ResolveDecision(s.base)
	if err != nil {
		return jsonResponse(http.StatusConflict, map[string]any{"error": map[string]any{
			"message": err.Error(), "type": "tradera_error", "code": "decision_disabled",
		}}), nil
	}
	answers, in, out, failed := a.askDecision(ctx, provider, req.Body)
	if failed != nil {
		return failed, nil
	}
	a.meterDecision(s, provider, in, out)
	return decisionAnswer(provider, answers, in, out), nil
}

// serveLearnDecision is the decision model for the agents' learning (their
// playbook improving between turns, runtime/tradera_agents/improve): the same
// typed questions, on the runtime's own credential for a project, billed to
// the project like the rest of its learning (learn.go).
//
//	POST {gateway}/learn/decision/evaluate
//	     X-Tradera-Runtime: the runtime secret; X-Tradera-Space
func (a *Adapter) serveLearnDecision(ctx context.Context, req *network.Request) (*network.Response, error) {
	space, refused := a.learnCaller(req)
	if refused != nil {
		return refused, nil
	}
	provider, err := a.platform.ResolveDecision(ctx)
	if err != nil {
		return jsonResponse(http.StatusConflict, map[string]any{"error": map[string]any{
			"message": err.Error(), "type": "tradera_error", "code": "decision_disabled",
		}}), nil
	}
	answers, in, out, failed := a.askDecision(ctx, provider, req.Body)
	if failed != nil {
		return failed, nil
	}
	a.learn.add(space, provider, in, out)
	return decisionAnswer(provider, answers, in, out), nil
}

// askDecision sends one evaluate request to the decision provider:
// {"state", "questions"} → its answers and token usage, or the response to
// answer with when it fails.
func (a *Adapter) askDecision(ctx context.Context, provider vmm.ProviderConfig, body []byte) (json.RawMessage, int64, int64, *network.Response) {
	var in struct {
		State     json.RawMessage            `json:"state"`
		Questions map[string]json.RawMessage `json:"questions"`
	}
	if err := json.Unmarshal(body, &in); err != nil || len(in.Questions) == 0 || len(in.State) == 0 {
		return nil, 0, 0, openAIError(400, "a decision needs a state and at least one question")
	}
	if len(in.Questions) > maxDecisionQuestions {
		return nil, 0, 0, openAIError(400, "too many questions in one decision")
	}
	payload, _ := json.Marshal(map[string]any{"model": provider.Model, "state": in.State, "questions": in.Questions})
	callCtx, cancel := context.WithTimeout(ctx, decisionTimeout)
	defer cancel()
	up, err := http.NewRequestWithContext(callCtx, http.MethodPost, decisionURL(provider.BaseURL), bytes.NewReader(payload))
	if err != nil {
		return nil, 0, 0, openAIError(500, err.Error())
	}
	up.Header.Set("Content-Type", "application/json")
	if provider.APIKey != "" {
		up.Header.Set("Authorization", "Bearer "+provider.APIKey)
	}
	resp, err := a.client.Do(up)
	if err != nil {
		return nil, 0, 0, openAIError(502, "decision provider unreachable: "+err.Error())
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, 0, 0, openAIError(502, "decision provider response failed: "+err.Error())
	}
	if resp.StatusCode >= 300 {
		return nil, 0, 0, openAIError(502, "decision provider refused the request: "+clip(strings.TrimSpace(string(data)), 500))
	}
	var out struct {
		Answers json.RawMessage `json:"answers"`
		Usage   struct {
			InputTokens  int64 `json:"inputTokens"`
			OutputTokens int64 `json:"outputTokens"`
		} `json:"usage"`
	}
	if json.Unmarshal(data, &out) != nil || len(out.Answers) == 0 {
		return nil, 0, 0, openAIError(502, "decision provider answered without answers")
	}
	return out.Answers, out.Usage.InputTokens, out.Usage.OutputTokens, nil
}

func decisionAnswer(provider vmm.ProviderConfig, answers json.RawMessage, in, out int64) *network.Response {
	return jsonResponse(200, map[string]any{"model": provider.Model, "answers": answers,
		"usage": map[string]any{"inputTokens": in, "outputTokens": out}})
}

// decisionURL is the decision API of a provider: its evaluate endpoint next
// to its OpenAI-compatible base (Vercel AI Gateway: …/v1/evaluate).
func decisionURL(base string) string {
	base = strings.TrimRight(base, "/")
	if strings.HasSuffix(base, "/evaluate") {
		return base
	}
	return base + "/evaluate"
}

// meterDecision prices a decision with the decision model's own token prices
// and meters it onto the turn. Decisions cost fractions of a ledger unit, so
// the turn carries the fraction and meters whole units as they add up.
func (a *Adapter) meterDecision(s *session, provider vmm.ProviderConfig, in, out int64) {
	cost := (float64(in)*provider.InputPrice + float64(out)*provider.OutputPrice) / 1e6
	// The tokens are recorded on the turn even when the model is free, so the
	// admin log shows that the decision model ran.
	if in > 0 || out > 0 {
		vmm.AddInvocationUsage(s.base, usage.Delta{DecisionIn: in, DecisionOut: out})
	}
	if cost <= 0 {
		return
	}
	s.mu.Lock()
	s.decisionCost += cost
	due := int64(math.Floor(s.decisionCost+1e-9)) - s.decisionCharged
	if due > 0 {
		s.decisionCharged += due
	}
	s.mu.Unlock()
	if due > 0 {
		vmm.AddInvocationUsage(s.base, usage.Delta{Decision: due})
	}
}
