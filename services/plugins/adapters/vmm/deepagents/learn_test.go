package deepagents

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

func learnRequest(t *testing.T, a *Adapter, secret string, space identity.ID, agent string) *network.Response {
	t.Helper()
	header := map[string]string{"X-Tradera-Runtime": secret, LearnAgentHeader: agent}
	if !space.IsZero() {
		header[LearnSpaceHeader] = space.String()
	}
	resp, err := a.serveLearn(context.Background(), &network.Request{Header: header,
		Body: []byte(`{"model":"anything","messages":[{"role":"user","content":"improve"}]}`)})
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func TestAgentsLearnOnTheirOwnModelAndTheirProjectPays(t *testing.T) {
	p := ids(t, 3)
	space, person, keyOwner := p[0], p[1], p[2]
	srv, got, auth := provider(t, func(string, map[string]any) string {
		return `{"choices":[{"message":{"role":"assistant","content":"<notes>ok</notes>"}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}`
	})
	a, charges, _ := billingAdapter(t, "", vmm.ProviderConfig{})
	a.platform = fakePlatform{provider: vmm.ProviderConfig{BaseURL: srv.URL + "/v1", APIKey: "sk-agent", Model: "agent-model",
		InputPrice: 1e6, OutputPrice: 2e6, OwnerID: keyOwner.String()}}
	a.memory.notePayer(space.String(), person.String())
	vm := onlyVM(t, a)

	if resp := learnRequest(t, a, "wrong", space, vm); resp.Status != 401 {
		t.Fatalf("only the runtime learns: %d", resp.Status)
	}
	if resp := learnRequest(t, a, "secret", identity.ID{}, vm); resp.Status != 400 {
		t.Fatalf("learning names its project: %d", resp.Status)
	}
	if resp := learnRequest(t, a, "secret", space, "nobody"); resp.Status != 404 {
		t.Fatalf("learning names its agent: %d", resp.Status)
	}
	resp := learnRequest(t, a, "secret", space, vm)
	if resp.Status != 200 || !strings.Contains(string(resp.Body), "<notes>ok</notes>") {
		t.Fatalf("%d %s", resp.Status, resp.Body)
	}
	if (*got)["model"] != "agent-model" || *auth != "Bearer sk-agent" {
		t.Fatalf("the agent's own provider and model: %v %q", (*got)["model"], *auth)
	}
	a.billMemory(context.Background())
	if len(*charges) != 1 {
		t.Fatalf("charges: %+v", *charges)
	}
	c := (*charges)[0]
	if c.space != space || c.payer != person || c.payee != keyOwner || c.amount != 7 || !strings.HasPrefix(c.desc, "agent learning") {
		t.Fatalf("charge: %+v", c)
	}
	usage, _ := a.Usage(context.Background(), vm)
	if usage.TokensIn != 3 || usage.TokensOut != 2 {
		t.Fatalf("the agent's usage counts its learning: %+v", usage)
	}
}

func TestTheDecisionModelJudgesAgentsLearningAndTheirProjectPays(t *testing.T) {
	p := ids(t, 3)
	space, person, keyOwner := p[0], p[1], p[2]
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"model":"jev","answers":{"sound":{"type":"boolean","probability":0.9}},
			"usage":{"inputTokens":4,"outputTokens":0}}`))
	}))
	t.Cleanup(upstream.Close)
	a, charges, _ := billingAdapter(t, "", vmm.ProviderConfig{})
	a.memory.notePayer(space.String(), person.String())
	judge := func(secret string) *network.Response {
		resp, err := a.serveLearnDecision(context.Background(), &network.Request{Body: []byte(question),
			Header: map[string]string{"X-Tradera-Runtime": secret, LearnSpaceHeader: space.String()}})
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}

	a.platform = fakePlatform{}
	if resp := judge("secret"); resp.Status != 409 {
		t.Fatalf("the decision model is off: %d", resp.Status)
	}
	a.platform = fakePlatform{decision: &vmm.ProviderConfig{BaseURL: upstream.URL + "/v1", Model: "jev",
		InputPrice: 1e6, OwnerID: keyOwner.String()}}
	if resp := judge("wrong"); resp.Status != 401 {
		t.Fatalf("only the runtime learns: %d", resp.Status)
	}
	resp := judge("secret")
	if resp.Status != 200 || !strings.Contains(string(resp.Body), `"probability":0.9`) {
		t.Fatalf("%d %s", resp.Status, resp.Body)
	}
	a.billMemory(context.Background())
	if len(*charges) != 1 || (*charges)[0].payer != person || (*charges)[0].amount != 4 ||
		!strings.HasPrefix((*charges)[0].desc, "agent learning") {
		t.Fatalf("charges: %+v", *charges)
	}
}

func TestAProjectThatCannotPayDoesNotLearn(t *testing.T) {
	p := ids(t, 2)
	space := p[0]
	a, _, _ := newTestAdapter(t)
	a.platform = fakePlatform{provider: vmm.ProviderConfig{Model: "m"}}
	a.learn.mu.Lock()
	a.learn.blocked[space.String()] = true
	a.learn.mu.Unlock()
	if resp := learnRequest(t, a, "secret", space, onlyVM(t, a)); resp.Status != 402 {
		t.Fatalf("blocked: %d", resp.Status)
	}
}

func TestTheGatewayServesTheMarketAndHiring(t *testing.T) {
	if !allowedActions["market.catalog"] || !allowedActions["spaces.agent_hire"] {
		t.Fatal("agents browse the marketplace and hire from it")
	}
	if allowedActions["market.publish"] || allowedActions["market.install"] {
		t.Fatal("agents do not publish, nor install outside the space's rules")
	}
}
