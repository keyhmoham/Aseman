package deepagents

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/tradera/tradera/plugins/adapters/network/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

func decide(t *testing.T, a *Adapter, body string) *network.Response {
	t.Helper()
	resp, err := a.serveDecision(context.Background(), &network.Request{
		Header: map[string]string{"Authorization": "Bearer tok"}, Body: []byte(body),
	})
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

const question = `{"state":{"request":"open a github issue"},"questions":{"t0":{"type":"boolean","instructions":"Is github needed?"}}}`

func TestServeDecisionForwardsToTheDecisionModelAndMeters(t *testing.T) {
	var got map[string]any
	var auth, path string
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth, path = r.Header.Get("Authorization"), r.URL.Path
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &got)
		_, _ = w.Write([]byte(`{"model":"typesafe-ai/jev","answers":{"t0":{"type":"boolean","probability":0.97}},
			"usage":{"inputTokens":400000,"outputTokens":0}}`))
	}))
	t.Cleanup(provider.Close)
	a, _, _ := newTestAdapter(t)
	a.platform = fakePlatform{decision: &vmm.ProviderConfig{BaseURL: provider.URL + "/v1", APIKey: "vck-key",
		Model: "typesafe-ai/jev", InputPrice: 5}}
	def, err := a.agent(onlyVM(t, a))
	if err != nil {
		t.Fatal(err)
	}
	usageCtx := vmm.WithInvocationUsage(context.Background())
	s := &session{token: "tok", def: def, base: usageCtx}
	a.sessions["tok"] = s

	resp := decide(t, a, question)
	if resp.Status != 200 {
		t.Fatalf("status %d: %s", resp.Status, resp.Body)
	}
	if path != "/v1/evaluate" || auth != "Bearer vck-key" || got["model"] != "typesafe-ai/jev" || got["questions"] == nil {
		t.Fatalf("upstream got path=%s auth=%s body=%v", path, auth, got)
	}
	var out struct {
		Answers map[string]struct {
			Probability float64 `json:"probability"`
		} `json:"answers"`
	}
	_ = json.Unmarshal(resp.Body, &out)
	if out.Answers["t0"].Probability != 0.97 {
		t.Fatalf("answers: %s", resp.Body)
	}
	// 400k tokens at 5 per 1M = 2 units: the fraction carries, whole units are metered.
	if d := vmm.InvocationFrom(usageCtx).Delta; d.Decision != 2 || d.TokensIn != 0 {
		t.Fatalf("decision usage = %+v", d)
	}
	decide(t, a, question) // 4 units in all
	if d := vmm.InvocationFrom(usageCtx).Delta; d.Decision != 4 {
		t.Fatalf("decision usage after two = %+v", d)
	}
	if s.tokIn != 0 {
		t.Fatal("decision tokens must not be priced as the agent model's tokens")
	}
}

func TestServeDecisionWhenOffOrBroken(t *testing.T) {
	a, _, _ := newTestAdapter(t)
	a.platform = fakePlatform{}
	def, err := a.agent(onlyVM(t, a))
	if err != nil {
		t.Fatal(err)
	}
	a.sessions["tok"] = &session{token: "tok", def: def, base: context.Background()}
	if resp := decide(t, a, question); resp.Status != http.StatusConflict {
		t.Fatalf("off must answer 409 decision_disabled, got %d %s", resp.Status, resp.Body)
	}
	down := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	t.Cleanup(down.Close)
	a.platform = fakePlatform{decision: &vmm.ProviderConfig{BaseURL: down.URL, Model: "typesafe-ai/jev"}}
	if resp := decide(t, a, question); resp.Status != http.StatusBadGateway {
		t.Fatalf("a failing provider must be a 502, got %d", resp.Status)
	}
	if resp := decide(t, a, `{"state":"x","questions":{}}`); resp.Status != http.StatusBadRequest {
		t.Fatalf("no questions must be a 400, got %d", resp.Status)
	}
	delete(a.sessions, "tok")
	if resp := decide(t, a, question); resp.Status != http.StatusUnauthorized {
		t.Fatalf("no turn must be a 401, got %d", resp.Status)
	}
}

func TestATurnCarriesTheDecisionSwitch(t *testing.T) {
	a, rt, _ := newTestAdapter(t)
	a.platform = fakePlatform{provider: vmm.ProviderConfig{Model: "m1"}}
	turn := testTurn()
	turn.Agent.AccountID = mustID(t)
	if _, err := a.Prompt(context.Background(), onlyVM(t, a), turn); err != nil {
		t.Fatal(err)
	}
	if rt.turns[0].Decision != nil {
		t.Fatal("off: the runtime must not be told to use a decision model")
	}
	a.platform = fakePlatform{provider: vmm.ProviderConfig{Model: "m1"}, decision: &vmm.ProviderConfig{Model: "typesafe-ai/jev"}}
	if _, err := a.Prompt(context.Background(), onlyVM(t, a), turn); err != nil {
		t.Fatal(err)
	}
	if d := rt.turns[1].Decision; d == nil || !d.Enabled || d.Model != "typesafe-ai/jev" {
		t.Fatalf("on: decision payload = %+v", d)
	}
}

func TestDecisionURL(t *testing.T) {
	for in, want := range map[string]string{
		"https://ai-gateway.vercel.sh/v1":          "https://ai-gateway.vercel.sh/v1/evaluate",
		"https://ai-gateway.vercel.sh/v1/":         "https://ai-gateway.vercel.sh/v1/evaluate",
		"https://ai-gateway.vercel.sh/v1/evaluate": "https://ai-gateway.vercel.sh/v1/evaluate",
	} {
		if got := decisionURL(in); got != want {
			t.Errorf("decisionURL(%q) = %q", in, got)
		}
	}
}
