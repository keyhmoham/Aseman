package deepagents

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
)

// Agents improve their own playbook as they work (runtime/tradera_agents/
// improve: GEPA, run between turns). That work belongs to no turn, so it is
// not on a turn's token: the runtime calls the learn endpoints with its own
// secret, naming the project and the agent. The agent's own model answers (the
// provider and model its definition names, as for its turns) and the node's
// decision model judges (serveLearnDecision), and the project pays for both
// like for its memory: at the models' token prices, to the owners of the
// providers' keys, in the project's spend and budget, charged every
// memoryBillEvery by whoever runs its agents. A project that cannot pay gets
// no learning until it can.
const (
	// LearnSpaceHeader names the project the learning is for.
	LearnSpaceHeader = "X-Tradera-Space"
	// LearnAgentHeader names the agent (its VM id) that is learning.
	LearnAgentHeader = "X-Tradera-Agent"
)

func headerValue(h map[string]string, name string) string {
	for k, v := range h {
		if strings.EqualFold(k, name) {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// learnCaller lets in only the runtime, for a project that can pay; it returns
// the project, or the response refusing the call.
func (a *Adapter) learnCaller(req *network.Request) (identity.ID, *network.Response) {
	if a.secret == "" || subtle.ConstantTimeCompare([]byte(headerValue(req.Header, "X-Tradera-Runtime")), []byte(a.secret)) != 1 {
		return identity.ID{}, openAIError(http.StatusUnauthorized, "invalid runtime secret")
	}
	space, err := identity.Parse(headerValue(req.Header, LearnSpaceHeader))
	if err != nil || space.IsZero() {
		return identity.ID{}, openAIError(http.StatusBadRequest, "name the project the learning is for ("+LearnSpaceHeader+")")
	}
	if a.learn.isBlocked(space) {
		return identity.ID{}, openAIError(http.StatusPaymentRequired, "this project cannot pay for its agents' learning now (wallet or budget)")
	}
	return space, nil
}

// serveLearn is the agents' model for learning: OpenAI's chat completions
// with the agent's own model.
//
//	POST {gateway}/learn/chat/completions
//	     X-Tradera-Runtime: the runtime secret; X-Tradera-Space, X-Tradera-Agent
func (a *Adapter) serveLearn(ctx context.Context, req *network.Request) (*network.Response, error) {
	space, refused := a.learnCaller(req)
	if refused != nil {
		return refused, nil
	}
	def, err := a.agent(headerValue(req.Header, LearnAgentHeader))
	if err != nil {
		return openAIError(http.StatusNotFound, "no such agent ("+LearnAgentHeader+")"), nil
	}
	def.mu.Lock()
	spec := def.spec
	def.mu.Unlock()
	provider, err := a.platform.ResolveChat(ctx, spec.Provider, spec.Model)
	if err != nil {
		return openAIError(http.StatusServiceUnavailable, "no LLM provider for this agent: "+err.Error()), nil
	}
	var body map[string]any
	if err := json.Unmarshal(req.Body, &body); err != nil {
		return openAIError(http.StatusBadRequest, "invalid request body"), nil
	}
	stream, _ := body["stream"].(bool)
	if stream {
		// The last chunk then says what the call used, for the bill.
		opts, _ := body["stream_options"].(map[string]any)
		if opts == nil {
			opts = map[string]any{}
		}
		opts["include_usage"] = true
		body["stream_options"] = opts
	}
	callCtx, cancel := context.WithTimeout(ctx, memoryTimeout)
	defer cancel()
	up, err := providerRequest(callCtx, provider, "/chat/completions", body)
	if err != nil {
		return openAIError(http.StatusInternalServerError, err.Error()), nil
	}
	if stream {
		up.Header.Set("Accept", "text/event-stream")
	}
	return a.forwardMemory(up, func(data []byte) ([]byte, error) {
		in, out := parseUsage(data, stream)
		a.learn.add(space, provider, in, out)
		def.mu.Lock()
		def.tokensIn += in
		def.tokensOut += out
		def.mu.Unlock()
		return data, nil
	})
}
