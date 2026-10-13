package llm

import (
	"context"
	"testing"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/llm/models"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/memory"
	dbmodel "github.com/tradera/tradera/plugins/testutil"
)

func harness(t *testing.T) (*Service, context.Context, identity.ID) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := context.Background()
	for _, m := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"node_private_key": testNodeKey}})
	admin, _ := identity.New(1)
	return NewService(k, &repo.Repo{DB: db}, logger.Global()), ctx, admin
}

func TestSetResolveAndDefaults(t *testing.T) {
	s, ctx, admin := harness(t)
	if _, _, err := s.Resolve(ctx, "", ""); err == nil {
		t.Fatal("resolve must fail with no provider configured")
	}
	oa, err := s.Set(ctx, admin, ProviderInput{Kind: llmprovider.KindOpenAI, APIKey: "sk-openai-123456",
		Models: []llmprovider.Model{{ID: "gpt-5.4", InputPrice: 1000, OutputPrice: 4000}, {ID: "gpt-5.4-mini", InputPrice: 100, OutputPrice: 400}}})
	if err != nil {
		t.Fatal(err)
	}
	if !oa.IsDefault || oa.BaseURL != "https://api.openai.com/v1" || oa.Name != "OpenAI" || oa.OwnerID != admin {
		t.Fatalf("unexpected provider: %+v", oa)
	}
	an, err := s.Set(ctx, admin, ProviderInput{Kind: llmprovider.KindAnthropic, APIKey: "sk-ant-abcdef",
		Models: []llmprovider.Model{{ID: "claude-sonnet-5-5", InputPrice: 3000, OutputPrice: 15000}}})
	if err != nil {
		t.Fatal(err)
	}
	if an.IsDefault {
		t.Fatal("second provider must not steal the default")
	}
	// Defaults: default provider, first model.
	p, m, err := s.Resolve(ctx, "", "")
	if err != nil || p.ID != oa.ID || m.ID != "gpt-5.4" {
		t.Fatalf("default resolve: %v %v %v", p, m, err)
	}
	// By id and by kind.
	if p, m, err = s.Resolve(ctx, an.ID.String(), "claude-sonnet-5-5"); err != nil || p.ID != an.ID || m.OutputPrice != 15000 {
		t.Fatalf("resolve by id: %v %v", m, err)
	}
	if p, _, err = s.Resolve(ctx, "anthropic", ""); err != nil || p.ID != an.ID {
		t.Fatalf("resolve by kind: %v", err)
	}
	// Unknown model is rejected.
	if _, _, err = s.Resolve(ctx, an.ID.String(), "gpt-5.4"); err == nil {
		t.Fatal("model of another provider must be rejected")
	}
	// Promote anthropic to default; update keeps the key when api_key is empty.
	if _, err = s.Set(ctx, admin, ProviderInput{ID: an.ID.String(), Kind: llmprovider.KindAnthropic, IsDefault: true,
		Models: []llmprovider.Model{{ID: "claude-sonnet-5-5", InputPrice: 3000, OutputPrice: 15000}}}); err != nil {
		t.Fatal(err)
	}
	if p, _, _ = s.Resolve(ctx, "", ""); p.ID != an.ID || p.APIKey != "sk-ant-abcdef" {
		t.Fatalf("default not moved or key lost: %+v", p)
	}
	if got, _ := s.Get(ctx, oa.ID); got.IsDefault {
		t.Fatal("old default must be cleared")
	}
	// Disabled providers do not resolve and leave the catalog.
	off := false
	if _, err = s.Set(ctx, admin, ProviderInput{ID: oa.ID.String(), Kind: llmprovider.KindOpenAI, Enabled: &off,
		Models: []llmprovider.Model{{ID: "gpt-5.4"}}}); err != nil {
		t.Fatal(err)
	}
	if _, _, err = s.Resolve(ctx, oa.ID.String(), ""); err == nil {
		t.Fatal("disabled provider must not resolve")
	}
	cat, _ := s.Catalog(ctx)
	if len(cat) != 1 || cat[0].ID != an.ID.String() {
		t.Fatalf("catalog: %+v", cat)
	}
	// Deleting the default promotes another enabled provider (none here).
	if err := s.Delete(ctx, an.ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err = s.Resolve(ctx, "", ""); err == nil {
		t.Fatal("no enabled provider should remain")
	}
}

func TestSetValidation(t *testing.T) {
	s, ctx, admin := harness(t)
	cases := []ProviderInput{
		{Kind: "nope", APIKey: "k", Models: []llmprovider.Model{{ID: "m"}}},
		{Kind: llmprovider.KindOpenAI, Models: []llmprovider.Model{{ID: "m"}}},              // no key
		{Kind: llmprovider.KindCustom, APIKey: "k", Models: []llmprovider.Model{{ID: "m"}}}, // no base url
		{Kind: llmprovider.KindOpenAI, APIKey: "k", Models: []llmprovider.Model{{ID: "m", InputPrice: -1}}},
		{Kind: llmprovider.KindOpenAI, APIKey: "k", Models: []llmprovider.Model{{ID: "m"}, {ID: "m"}}},
	}
	for i, c := range cases {
		if _, err := s.Set(ctx, admin, c); err == nil {
			t.Errorf("case %d: expected validation error", i)
		}
	}
}

// A provider can be added before it has models (they are added on the Models page);
// until then nothing can run on it.
func TestProviderWithoutModelsIsAcceptedButCannotRunAnything(t *testing.T) {
	s, ctx, admin := harness(t)
	p, err := s.Set(ctx, admin, ProviderInput{Kind: llmprovider.KindOpenAI, APIKey: "k"})
	if err != nil {
		t.Fatalf("a provider without models was refused: %v", err)
	}
	if len(p.ParseModels()) != 0 {
		t.Fatalf("models = %v; want none", p.ParseModels())
	}
	if _, _, err := s.Resolve(ctx, "", ""); err == nil {
		t.Fatal("an agent resolved a model on a provider that has none")
	}
	// Models are added afterwards.
	p, err = s.Set(ctx, admin, ProviderInput{ID: p.ID.String(), Kind: llmprovider.KindOpenAI, Models: []llmprovider.Model{{ID: "gpt-x"}}})
	if err != nil {
		t.Fatal(err)
	}
	if _, m, err := s.Resolve(ctx, "", ""); err != nil || m.ID != "gpt-x" {
		t.Fatalf("after adding a model: %v, %v", m, err)
	}
}

func TestPriceTokenCost(t *testing.T) {
	p := Price{InputPrice: 1000, OutputPrice: 4000}
	if got := p.TokenCost(0, 0); got != 0 {
		t.Fatalf("no tokens = %d", got)
	}
	// 1500 in → 1.5, 250 out → 1.0 → 2.5 → ceil 3.
	if got := p.TokenCost(1500, 250); got != 3 {
		t.Fatalf("cost = %d, want 3", got)
	}
	if got := (Price{}).TokenCost(10, 10); got != 0 {
		t.Fatalf("free model = %d", got)
	}
	// Exactly whole credits do not round up.
	if got := p.TokenCost(2000, 0); got != 2 {
		t.Fatalf("cost = %d, want 2", got)
	}
}

func TestSeedIfEmptyAndImageResolve(t *testing.T) {
	s, ctx, admin := harness(t)
	in := ProviderInput{Kind: llmprovider.KindOpenAI, APIKey: "sk-static", ImageModel: "gpt-image-1", ImagePrice: 20,
		Models: []llmprovider.Model{{ID: "gpt-5.4", InputPrice: 1, OutputPrice: 2}}}
	if ok, err := s.SeedIfEmpty(ctx, admin, in); err != nil || !ok {
		t.Fatalf("seed: %v %v", ok, err)
	}
	if ok, _ := s.SeedIfEmpty(ctx, admin, in); ok {
		t.Fatal("seed must only run once")
	}
	img, err := s.ResolveImage(ctx, "")
	if err != nil || img.ImageModel != "gpt-image-1" || img.ImagePrice != 20 {
		t.Fatalf("image resolve: %+v %v", img, err)
	}
	price, err := s.PriceFor(ctx, "", "gone-model")
	if err != nil || price.Payee != admin || price.InputPrice != 1 {
		t.Fatalf("price fallback: %+v %v", price, err)
	}
}
