package llm

import (
	"testing"

	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/llm/models"
)

func TestDecisionModelsAreNeverAgentBackbones(t *testing.T) {
	s, ctx, admin := harness(t)
	v, err := s.Set(ctx, admin, ProviderInput{Kind: llmprovider.KindVercel, APIKey: "vck-123456789",
		Models: []llmprovider.Model{{ID: "typesafe-ai/jev", InputPrice: 42}, {ID: "openai/gpt-5.4", InputPrice: 1000, OutputPrice: 4000}}})
	if err != nil {
		t.Fatal(err)
	}
	if v.BaseURL != "https://ai-gateway.vercel.sh/v1" {
		t.Fatalf("vercel preset base url: %s", v.BaseURL)
	}
	jev, _ := v.Model("typesafe-ai/jev")
	if !jev.Decision() || jev.Chat() {
		t.Fatalf("jev must default to a decision-only model: %+v", jev)
	}
	// The first model is jev, yet an agent without a model gets the chat one.
	if _, m, err := s.Resolve(ctx, "", ""); err != nil || m.ID != "openai/gpt-5.4" {
		t.Fatalf("default model must be a chat model: %v %v", m, err)
	}
	if _, _, err := s.Resolve(ctx, "", "typesafe-ai/jev"); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("an agent cannot run on a decision model: %v", err)
	}
	catalog, err := s.Catalog(ctx)
	if err != nil || len(catalog) != 1 || len(catalog[0].Models) != 1 || catalog[0].Models[0].ID != "openai/gpt-5.4" {
		t.Fatalf("catalog must hide decision models: %+v %v", catalog, err)
	}
	if _, err := s.Set(ctx, admin, ProviderInput{Kind: llmprovider.KindOpenAI, APIKey: "sk-x-123456",
		Models: []llmprovider.Model{{ID: "m", Capabilities: []string{"telepathy"}}}}); err == nil {
		t.Fatal("unknown capabilities must be refused")
	}
}

func TestDecisionSettingOnOffAndFallback(t *testing.T) {
	s, ctx, admin := harness(t)
	if _, err := s.ResolveDecision(ctx); errs.CodeOf(err) != errs.CodeUnavailable {
		t.Fatalf("off by default: %v", err)
	}
	v, err := s.Set(ctx, admin, ProviderInput{Kind: llmprovider.KindVercel, APIKey: "vck-123456789",
		Models: []llmprovider.Model{{ID: "typesafe-ai/jev", InputPrice: 42}, {ID: "openai/gpt-5.4"}}})
	if err != nil {
		t.Fatal(err)
	}
	// Only decision models can be picked.
	if _, err := s.SetDecision(ctx, DecisionInput{Enabled: true, ProviderID: v.ID.String(), ModelID: "openai/gpt-5.4"}); err == nil {
		t.Fatal("a chat model cannot be the decision model")
	}
	if _, err := s.SetDecision(ctx, DecisionInput{Enabled: true}); err == nil {
		t.Fatal("turning it on needs a provider and model")
	}
	if _, err := s.SetDecision(ctx, DecisionInput{Enabled: true, ProviderID: v.ID.String(), ModelID: "typesafe-ai/jev"}); err != nil {
		t.Fatal(err)
	}
	cfg, err := s.ResolveDecision(ctx)
	if err != nil || cfg.Model != "typesafe-ai/jev" || cfg.APIKey != "vck-123456789" || cfg.InputPrice != 42 ||
		cfg.BaseURL != "https://ai-gateway.vercel.sh/v1" {
		t.Fatalf("resolve decision: %+v %v", cfg, err)
	}
	view, err := s.decisionView(ctx)
	if err != nil || view["active"] != true {
		t.Fatalf("view: %v %v", view, err)
	}
	// Off keeps the choice but resolves to nothing.
	if _, err := s.SetDecision(ctx, DecisionInput{Enabled: false, ProviderID: v.ID.String(), ModelID: "typesafe-ai/jev"}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ResolveDecision(ctx); errs.CodeOf(err) != errs.CodeUnavailable {
		t.Fatalf("off must not resolve: %v", err)
	}
	d, _ := s.Decision(ctx)
	if d.ModelID != "typesafe-ai/jev" {
		t.Fatalf("off keeps the pick: %+v", d)
	}
	// On again, then the provider is disabled: agents fall back to their own model.
	if _, err := s.SetDecision(ctx, DecisionInput{Enabled: true, ProviderID: v.ID.String(), ModelID: "typesafe-ai/jev"}); err != nil {
		t.Fatal(err)
	}
	off := false
	if _, err := s.Set(ctx, admin, ProviderInput{ID: v.ID.String(), Kind: llmprovider.KindVercel, Enabled: &off,
		Models: []llmprovider.Model{{ID: "typesafe-ai/jev", InputPrice: 42}}}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ResolveDecision(ctx); errs.CodeOf(err) != errs.CodeUnavailable {
		t.Fatalf("a disabled provider must fall back: %v", err)
	}
	if view, _ := s.decisionView(ctx); view["active"] != false || view["enabled"] != true {
		t.Fatalf("view must say on but unusable: %v", view)
	}
}
