package llm

import (
	"testing"

	"github.com/tradera/tradera/plugins/actions/llm/models"
)

func TestADisabledModelIsOfferedNowhereButKeepsRunning(t *testing.T) {
	s, ctx, admin := harness(t)
	p, err := s.Set(ctx, admin, ProviderInput{Kind: llmprovider.KindOpenAI, APIKey: "sk-openai-123456", Models: []llmprovider.Model{
		{ID: "gpt-5-mini", InputPrice: 1},
		{ID: "gpt-5-old", InputPrice: 1, Disabled: true},
		{ID: "text-embedding-3-small", InputPrice: 1, Disabled: true},
		{ID: "typesafe-ai/jev", InputPrice: 1, Disabled: true},
	}})
	if err != nil {
		t.Fatal(err)
	}
	cat, _ := s.Catalog(ctx)
	if len(cat) != 1 || len(cat[0].Models) != 1 || cat[0].Models[0].ID != "gpt-5-mini" {
		t.Fatalf("new agents are offered only the enabled model: %+v", cat)
	}
	off, _ := s.Offerings(ctx)
	if len(off) != 1 || off[0].Model != "gpt-5-mini" {
		t.Fatalf("the developer API serves only the enabled model: %+v", off)
	}
	view, _ := s.decisionView(ctx)
	if provs := view["providers"].([]map[string]any); len(provs) != 1 || len(provs[0]["decision_models"].([]llmprovider.Model)) != 0 {
		t.Fatalf("a disabled decision model is not offered: %+v", view["providers"])
	}
	// An agent already set to it keeps running on it.
	if _, m, err := s.Resolve(ctx, p.ID.String(), "gpt-5-old"); err != nil || m.ID != "gpt-5-old" {
		t.Fatalf("resolve: %v %+v", err, m)
	}
	// An empty model picks the first enabled one.
	if _, m, _ := s.Resolve(ctx, p.ID.String(), ""); m.ID != "gpt-5-mini" {
		t.Fatalf("default: %+v", m)
	}
}
