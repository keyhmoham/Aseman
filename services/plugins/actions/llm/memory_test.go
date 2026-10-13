package llm

import (
	"testing"

	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/llm/models"
)

func TestEmbeddingModelsAreNeverAgentBackbones(t *testing.T) {
	s, ctx, admin := harness(t)
	v, err := s.Set(ctx, admin, ProviderInput{Kind: llmprovider.KindOpenAI, APIKey: "sk-123456789",
		Models: []llmprovider.Model{{ID: "text-embedding-3-small", InputPrice: 2}, {ID: "gpt-5.4", InputPrice: 1000}}})
	if err != nil {
		t.Fatal(err)
	}
	embed, _ := v.Model("text-embedding-3-small")
	if !embed.Embedding() || embed.Chat() {
		t.Fatalf("an embedding model defaults to embedding only: %+v", embed)
	}
	if _, m, err := s.Resolve(ctx, "", ""); err != nil || m.ID != "gpt-5.4" {
		t.Fatalf("the default agent model is a chat model: %v %v", m, err)
	}
	catalog, err := s.Catalog(ctx)
	if err != nil || len(catalog[0].Models) != 1 {
		t.Fatalf("the catalog hides embedding models: %+v %v", catalog, err)
	}
	// Marked explicitly, any model can be one.
	v, err = s.Set(ctx, admin, ProviderInput{ID: v.ID.String(), Kind: llmprovider.KindOpenAI,
		Models: []llmprovider.Model{{ID: "my-vectors", Capabilities: []string{"embedding"}}, {ID: "gpt-5.4"}}})
	if err != nil {
		t.Fatal(err)
	}
	if m, _ := v.Model("my-vectors"); !m.Embedding() || m.Chat() {
		t.Fatalf("marked embedding model: %+v", m)
	}
}

func TestMemoryModelsSetting(t *testing.T) {
	s, ctx, admin := harness(t)
	if _, err := s.ResolveMemoryChat(ctx); errs.CodeOf(err) != errs.CodeUnavailable {
		t.Fatalf("no chat model by default: %v", err)
	}
	if _, err := s.ResolveMemoryEmbedding(ctx); errs.CodeOf(err) != errs.CodeUnavailable {
		t.Fatalf("no embedding model by default: %v", err)
	}
	v, err := s.Set(ctx, admin, ProviderInput{Kind: llmprovider.KindOpenAI, APIKey: "sk-123456789",
		Models: []llmprovider.Model{{ID: "text-embedding-3-small", InputPrice: 2}, {ID: "gpt-5.4-mini", InputPrice: 150, OutputPrice: 600}}})
	if err != nil {
		t.Fatal(err)
	}
	id := v.ID.String()
	// Each slot takes only its kind of model.
	if _, err := s.SetMemory(ctx, MemoryInput{ChatProviderID: id, ChatModelID: "text-embedding-3-small"}); err == nil {
		t.Fatal("an embedding model cannot extract memories")
	}
	if _, err := s.SetMemory(ctx, MemoryInput{EmbeddingProviderID: id, EmbeddingModelID: "gpt-5.4-mini"}); err == nil {
		t.Fatal("a chat model cannot embed")
	}
	if _, err := s.SetMemory(ctx, MemoryInput{ChatProviderID: id}); err == nil {
		t.Fatal("a provider needs its model")
	}
	// One model alone is allowed (partly in effect).
	if _, err := s.SetMemory(ctx, MemoryInput{EmbeddingProviderID: id, EmbeddingModelID: "text-embedding-3-small"}); err != nil {
		t.Fatal(err)
	}
	if view, _ := s.memoryView(ctx); view["embedding_active"] != true || view["chat_active"] != false || view["active"] != false {
		t.Fatalf("partly in effect: %v", view)
	}
	if _, err := s.SetMemory(ctx, MemoryInput{ChatProviderID: id, ChatModelID: "gpt-5.4-mini",
		EmbeddingProviderID: id, EmbeddingModelID: "text-embedding-3-small"}); err != nil {
		t.Fatal(err)
	}
	chat, err := s.ResolveMemoryChat(ctx)
	if err != nil || chat.Model != "gpt-5.4-mini" || chat.APIKey != "sk-123456789" || chat.BaseURL != "https://api.openai.com/v1" ||
		chat.InputPrice != 150 || chat.OutputPrice != 600 || chat.OwnerID != admin.String() {
		t.Fatalf("resolve chat: %+v %v", chat, err)
	}
	embed, err := s.ResolveMemoryEmbedding(ctx)
	if err != nil || embed.Model != "text-embedding-3-small" {
		t.Fatalf("resolve embedding: %+v %v", embed, err)
	}
	view, err := s.memoryView(ctx)
	if err != nil || view["active"] != true {
		t.Fatalf("view: %v %v", view, err)
	}
	providers := view["providers"].([]map[string]any)
	if len(providers[0]["chat_models"].([]llmprovider.Model)) != 1 || len(providers[0]["embedding_models"].([]llmprovider.Model)) != 1 {
		t.Fatalf("each picker lists its kind of model: %v", providers)
	}
	// A disabled provider stops it, keeping the choice.
	off := false
	if _, err := s.Set(ctx, admin, ProviderInput{ID: id, Kind: llmprovider.KindOpenAI, Enabled: &off,
		Models: []llmprovider.Model{{ID: "text-embedding-3-small"}, {ID: "gpt-5.4-mini"}}}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ResolveMemoryChat(ctx); errs.CodeOf(err) != errs.CodeUnavailable {
		t.Fatalf("a disabled provider is unusable: %v", err)
	}
	if m, _ := s.Memory(ctx); m.ChatModelID != "gpt-5.4-mini" {
		t.Fatalf("the choice is kept: %+v", m)
	}
	// Clearing both is allowed.
	if _, err := s.SetMemory(ctx, MemoryInput{}); err != nil {
		t.Fatal(err)
	}
}
