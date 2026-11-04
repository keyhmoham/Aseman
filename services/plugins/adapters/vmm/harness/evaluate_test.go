package harness

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
	"github.com/aseman/aseman/plugins/actions/usage/models/usage"
)

// serveEvaluate forwards a turn's decision to the node's decision model, meters
// its own prices onto the turn, and returns the answers.
func TestServeEvaluateCallsTheDecisionModelAndMetersIt(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/evaluate" || r.Header.Get("Authorization") != "Bearer k" {
			t.Fatalf("upstream %s %s", r.Method, r.URL.Path)
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["model"] != "typesafe-ai/jev" || body["state"] != "pick a color" {
			t.Fatalf("body %+v", body)
		}
		qs, _ := body["questions"].(map[string]any)
		if qs["blue"] == nil {
			t.Fatalf("questions %+v", qs)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"model": "typesafe-ai/jev",
			"answers": map[string]any{
				"blue": map[string]any{"type": "boolean", "probability": 0.88},
			},
			"usage": map[string]any{"inputTokens": 2_000_000, "outputTokens": 0},
		})
	}))
	defer upstream.Close()

	a, _, _ := newTestAdapter(t)
	decision := vmm.ProviderConfig{
		BaseURL: upstream.URL + "/v1", APIKey: "k", Model: "typesafe-ai/jev",
		InputPrice: 42_000, OutputPrice: 0,
	}
	a.platform = fakePlatform{decision: &decision}
	a.client = upstream.Client()
	a.gateFn = func(context.Context, identity.ID, identity.ID, int64, int64, int64) error { return nil }

	base := vmm.WithInvocationUsage(context.Background())
	payer, _ := identity.New(1)
	bot, _ := identity.New(1)
	base = vmm.WithExecution(base, vmm.Execution{ActorID: payer.String()})
	s := &session{token: "tok", def: a.agents[onlyVM(t, a)], botID: bot.String(), base: base}
	a.sessions["tok"] = s

	body := `{"state":"pick a color","questions":{"blue":{"type":"boolean","instructions":"Is blue better?"}}}`
	resp, err := a.serveEvaluate(context.Background(), &network.Request{
		Header: map[string]string{"Authorization": "Bearer tok"},
		Body:   []byte(body),
	})
	if err != nil || resp.Status != 200 {
		t.Fatalf("serveEvaluate = %v %d %s", err, resp.Status, resp.Body)
	}
	var out map[string]any
	_ = json.Unmarshal(resp.Body, &out)
	answers, _ := out["answers"].(map[string]any)
	if out["model"] != "typesafe-ai/jev" || answers["blue"] == nil {
		t.Fatalf("reply %+v", out)
	}
	// 2M input tokens at 42_000 / 1M = 84_000 ledger units.
	delta := vmm.InvocationFrom(base).Take(true)
	if delta.Decision != 84_000 || delta.DecisionIn != 2_000_000 || delta.DecisionOut != 0 {
		t.Fatalf("metered %+v", delta)
	}
	if s.decisionCharged != 84_000 {
		t.Fatalf("session decisionCharged = %d", s.decisionCharged)
	}
}

func TestServeEvaluateRefusesWhenTheDecisionModelIsOff(t *testing.T) {
	a, _, _ := newTestAdapter(t)
	a.platform = fakePlatform{} // no decision
	s := &session{token: "tok", base: context.Background()}
	a.sessions["tok"] = s
	resp, err := a.serveEvaluate(context.Background(), &network.Request{
		Header: map[string]string{"Authorization": "Bearer tok"},
		Body:   []byte(`{"state":"x","questions":{"y":{"type":"boolean"}}}`),
	})
	if err != nil || resp.Status != 503 || !strings.Contains(string(resp.Body), "decision model is off") {
		t.Fatalf("got %v %d %s", err, resp.Status, resp.Body)
	}
}

func TestServeEvaluateNeedsStateAndQuestions(t *testing.T) {
	a, _, _ := newTestAdapter(t)
	decision := vmm.ProviderConfig{BaseURL: "http://example.invalid/v1", Model: "jev"}
	a.platform = fakePlatform{decision: &decision}
	s := &session{token: "tok", base: context.Background()}
	a.sessions["tok"] = s
	resp, err := a.serveEvaluate(context.Background(), &network.Request{
		Header: map[string]string{"Authorization": "Bearer tok"},
		Body:   []byte(`{"state":"only"}`),
	})
	if err != nil || resp.Status != 400 {
		t.Fatalf("got %v %d %s", err, resp.Status, resp.Body)
	}
}

func TestMeterDecisionCeilPricesAtTheDecisionModel(t *testing.T) {
	a, _, _ := newTestAdapter(t)
	base := vmm.WithInvocationUsage(context.Background())
	s := &session{base: base}
	provider := vmm.ProviderConfig{InputPrice: 1_000_000, OutputPrice: 0} // 1 credit / token
	a.meterDecision(s, provider, 1, 0)
	delta := vmm.InvocationFrom(base).Take(true)
	if delta != (usage.Delta{Decision: 1, DecisionIn: 1}) {
		t.Fatalf("delta %+v", delta)
	}
}
