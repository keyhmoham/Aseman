package llm

import (
	"testing"

	"github.com/aseman/aseman/plugins/actions/llm/models"
)

func TestOfferingsListEveryServableModelWithItsEndpointAndOwner(t *testing.T) {
	s, ctx, admin := harness(t)
	if _, err := s.Set(ctx, admin, ProviderInput{Kind: llmprovider.KindOpenAI, APIKey: "sk-openai-123456", ImageModel: "gpt-image-1", ImagePrice: 40_000,
		Models: []llmprovider.Model{{ID: "gpt-5-mini", InputPrice: 250_000, OutputPrice: 2_000_000}, {ID: "text-embedding-3-small", InputPrice: 20_000}, {ID: "jev", InputPrice: 100_000}}}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Set(ctx, admin, ProviderInput{Kind: llmprovider.KindOpenRouter, APIKey: "sk-or-abcdef", Models: []llmprovider.Model{{ID: "openai/gpt-5-mini", InputPrice: 260_000, OutputPrice: 2_100_000}}}); err != nil {
		t.Fatal(err)
	}
	off := false
	if _, err := s.Set(ctx, admin, ProviderInput{Kind: llmprovider.KindGroq, APIKey: "gsk-abcdef", Enabled: &off, Models: []llmprovider.Model{{ID: "llama-4"}}}); err != nil {
		t.Fatal(err)
	}
	got, err := s.Offerings(ctx)
	if err != nil {
		t.Fatal(err)
	}
	types := map[string]string{}
	for _, o := range got {
		types[o.Slug+"/"+o.Model] = o.Type
		if o.APIKey == "" || o.BaseURL == "" || o.Owner != admin {
			t.Fatalf("an offering carries its endpoint, key and owner: %+v", o)
		}
	}
	want := map[string]string{"openai/gpt-5-mini": "chat", "openai/text-embedding-3-small": "embedding", "openai/jev": "decision", "openai/gpt-image-1": "image", "openrouter/openai/gpt-5-mini": "chat"}
	if len(types) != len(want) {
		t.Fatalf("got %v, want %v (a disabled provider offers nothing)", types, want)
	}
	for k, v := range want {
		if types[k] != v {
			t.Fatalf("%s: got %q want %q in %v", k, types[k], v, types)
		}
	}
}
