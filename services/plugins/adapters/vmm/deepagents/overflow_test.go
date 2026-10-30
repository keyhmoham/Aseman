package deepagents

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// fakePlatform resolves every agent's model to one provider endpoint.
type fakePlatform struct {
	provider vmm.ProviderConfig
	// decision is the node's decision model; nil means it is off.
	decision *vmm.ProviderConfig
	// memoryChat / memoryEmbedding are the memory's models; nil means unset.
	memoryChat, memoryEmbedding *vmm.ProviderConfig
	// timeline answers the spaces' timeline MCP; nil means it is off.
	timeline func(spaceID string, body []byte) ([]byte, error)
	// openCode is the node's programmer OpenCode switch.
	openCode bool
	// agentEngine is the agentic engine ("deepagents" or "opencode").
	agentEngine string
}

func (p fakePlatform) ResolveMemoryChat(context.Context) (vmm.ProviderConfig, error) {
	if p.memoryChat == nil {
		return vmm.ProviderConfig{}, errs.New(errs.CodeUnavailable, "no memory chat model is chosen")
	}
	return *p.memoryChat, nil
}

func (p fakePlatform) ResolveMemoryEmbedding(context.Context) (vmm.ProviderConfig, error) {
	if p.memoryEmbedding == nil {
		return vmm.ProviderConfig{}, errs.New(errs.CodeUnavailable, "no memory embedding model is chosen")
	}
	return *p.memoryEmbedding, nil
}

func (p fakePlatform) TimelineEnabled(context.Context) (bool, error) { return p.timeline != nil, nil }

func (p fakePlatform) OpenCodeEnabled(context.Context) (bool, error) { return p.openCode, nil }

func (p fakePlatform) AgentEngine(context.Context) (string, error) {
	if p.agentEngine == "" {
		return "deepagents", nil
	}
	return p.agentEngine, nil
}

func (p fakePlatform) TimelineMCP(_ context.Context, spaceID string, body []byte) ([]byte, error) {
	if p.timeline == nil {
		return nil, errs.New(errs.CodeUnavailable, "the timeline is not configured")
	}
	return p.timeline(spaceID, body)
}

func (p fakePlatform) CodeModeMCP(context.Context, string, []byte) ([]byte, error) {
	return []byte(`{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}`), nil
}

func (p fakePlatform) ResolveChat(context.Context, string, string) (vmm.ProviderConfig, error) {
	return p.provider, nil
}

func (p fakePlatform) ResolveDecision(context.Context) (vmm.ProviderConfig, error) {
	if p.decision == nil {
		return vmm.ProviderConfig{}, errs.New(errs.CodeUnavailable, "the decision model is off")
	}
	return *p.decision, nil
}

func TestContextOverflowRecognizesProviderWordings(t *testing.T) {
	cases := []struct {
		status int
		body   string
		want   bool
	}{
		{500, `{"error":{"message":"context limit exceeded"}}`, true},
		{400, `[{"error":{"code":400,"message":"The input token count (1200000) exceeds the maximum number of tokens allowed (1048576)."}}]`, true},
		{413, `{"error":"prompt is too long: 210000 tokens > 200000 maximum"}`, true},
		{200, "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: {\"error\":{\"message\":\"maximum context length is 32768 tokens\"}}\n\n", true},
		{429, `{"error":{"message":"Rate limit reached for gpt-4o in organization on tokens per min (TPM): context length"}}`, false},
		{400, `{"error":{"message":"invalid tool schema"}}`, false},
		{200, "data: {\"choices\":[{\"delta\":{\"content\":\"the context window of a model is…\"}}]}\n\ndata: [DONE]\n", false},
	}
	for _, c := range cases {
		if _, got := contextOverflow(c.status, []byte(c.body)); got != c.want {
			t.Errorf("contextOverflow(%d, %q) = %v, want %v", c.status, c.body, got, c.want)
		}
	}
}

func TestServeChatReportsAnOverflowInOpenAIsForm(t *testing.T) {
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":{"message":"context limit exceeded"}}`))
	}))
	t.Cleanup(provider.Close)
	a, _, _ := newTestAdapter(t)
	a.platform = fakePlatform{provider: vmm.ProviderConfig{BaseURL: provider.URL, Model: "m1"}}
	def, err := a.agent(onlyVM(t, a))
	if err != nil {
		t.Fatal(err)
	}
	a.sessions["tok"] = &session{token: "tok", def: def, base: context.Background()}
	resp, err := a.serveChat(context.Background(), &network.Request{
		Header: map[string]string{"Authorization": "Bearer tok"},
		Body:   []byte(`{"model":"m1","messages":[{"role":"user","content":"hi"}]}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal(resp.Body, &out)
	if resp.Status != http.StatusBadRequest || out.Error.Code != "context_length_exceeded" ||
		!strings.Contains(out.Error.Message, "context limit exceeded") {
		t.Fatalf("got %d %s", resp.Status, resp.Body)
	}
}

func TestATurnCarriesTheModelsContextWindow(t *testing.T) {
	a, rt, _ := newTestAdapter(t)
	a.platform = fakePlatform{provider: vmm.ProviderConfig{Model: "m1", ContextWindow: 32_768}}
	turn := testTurn()
	turn.Agent.AccountID = mustID(t)
	if _, err := a.Prompt(context.Background(), onlyVM(t, a), turn); err != nil {
		t.Fatal(err)
	}
	if got := rt.turns[0].Agent.ContextWindow; got != 32_768 {
		t.Fatalf("context window sent to the runtime = %d", got)
	}
}
