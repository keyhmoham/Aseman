package llm

import (
	"context"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/openviking"
	"github.com/tradera/tradera/plugins/actions/llm/models"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// memoryTable is the database model of the memory models setting.
const memoryTable = "llm_memory"

func (s *Service) memoryID() string { return s.K.NodeID().String() + "memory" }

// MemoryInput is the admin form of the memory models setting. Empty ids clear
// that model.
type MemoryInput struct {
	ChatProviderID      string `json:"chat_provider_id"`
	ChatModelID         string `json:"chat_model_id"`
	EmbeddingProviderID string `json:"embedding_provider_id"`
	EmbeddingModelID    string `json:"embedding_model_id"`
}

// Memory returns the stored memory models setting (none chosen when never set).
func (s *Service) Memory(ctx context.Context) (*llmprovider.Memory, error) {
	var m llmprovider.Memory
	err := s.R.GetString(ctx, memoryTable, s.memoryID(), &m)
	if errs.CodeOf(err) == errs.CodeNotFound {
		return &llmprovider.Memory{ID: s.memoryID()}, nil
	}
	if err != nil {
		return nil, err
	}
	return &m, nil
}

// SetMemory stores the memory models setting. Each model must be one of an
// enabled provider with an API key: a chat model for the chat model and a
// model marked as an embedding model for the embedding model.
func (s *Service) SetMemory(ctx context.Context, in MemoryInput) (*llmprovider.Memory, error) {
	in.ChatProviderID, in.ChatModelID = strings.TrimSpace(in.ChatProviderID), strings.TrimSpace(in.ChatModelID)
	in.EmbeddingProviderID, in.EmbeddingModelID = strings.TrimSpace(in.EmbeddingProviderID), strings.TrimSpace(in.EmbeddingModelID)
	if in.ChatProviderID != "" || in.ChatModelID != "" {
		if _, _, err := s.memoryModel(ctx, in.ChatProviderID, in.ChatModelID, llmprovider.CapabilityChat); err != nil {
			return nil, err
		}
	}
	if in.EmbeddingProviderID != "" || in.EmbeddingModelID != "" {
		if _, _, err := s.memoryModel(ctx, in.EmbeddingProviderID, in.EmbeddingModelID, llmprovider.CapabilityEmbedding); err != nil {
			return nil, err
		}
	}
	m, err := s.Memory(ctx)
	if err != nil {
		return nil, err
	}
	creating := m.UpdatedAt.IsZero()
	embeddingChanged := m.EmbeddingProviderID != in.EmbeddingProviderID || m.EmbeddingModelID != in.EmbeddingModelID
	hadEmbedding := m.EmbeddingModelID != ""
	m.ChatProviderID, m.ChatModelID = in.ChatProviderID, in.ChatModelID
	m.EmbeddingProviderID, m.EmbeddingModelID = in.EmbeddingProviderID, in.EmbeddingModelID
	m.UpdatedAt = time.Now().UTC()
	if creating {
		err = s.R.DB.Create(ctx, memoryTable, m.ID, m)
	} else {
		err = s.R.DB.Update(ctx, memoryTable, m.ID, m)
	}
	if err != nil {
		return nil, err
	}
	if embeddingChanged && (hadEmbedding || m.EmbeddingModelID != "") {
		// Vectors of another model (or none, when memories were kept without
		// one) are meaningless to the new one.
		go s.reindexMemory(m.EmbeddingModelID)
	}
	return m, nil
}

// reindexMemory has OpenViking recompute every space's vectors with the
// current embedding model, in the background.
func (s *Service) reindexMemory(model string) {
	ov := openviking.FromEnv()
	if ov == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	accounts, err := ov.Accounts(ctx, "space-*")
	if err != nil {
		s.L.Warn("memory reindex: list spaces", "error", err)
		return
	}
	failed := 0
	for _, account := range accounts {
		for _, uri := range []string{"viking://resources", "viking://user"} {
			if err := reindexOne(ctx, ov, account, uri); err != nil && !openviking.NotFound(err) {
				failed++
				s.L.Warn("memory reindex", "account", account, "uri", uri, "error", err)
			}
		}
	}
	s.L.Info("memory reindex started", "embedding_model", model, "spaces", len(accounts), "failed", failed)
}

// reindexOne starts the reindex of one tree, waiting out the moments it is
// busy (OpenViking is still processing what was just written to it).
func reindexOne(ctx context.Context, ov *openviking.Client, account, uri string) error {
	var err error
	for attempt := 0; attempt < 6; attempt++ {
		if err = ov.Reindex(ctx, account, uri); err == nil || !openviking.Busy(err) {
			return err
		}
		select {
		case <-ctx.Done():
			return err
		case <-time.After(time.Duration(attempt+1) * 5 * time.Second):
		}
	}
	return err
}

// memoryModel resolves a provider (by id) and one of its models with the
// capability the memory needs of it.
func (s *Service) memoryModel(ctx context.Context, providerID, modelID, capability string) (*llmprovider.Provider, llmprovider.Model, error) {
	what := "chat model"
	if capability == llmprovider.CapabilityEmbedding {
		what = "embedding model"
	}
	if providerID == "" || modelID == "" {
		return nil, llmprovider.Model{}, errs.InvalidArgument("pick a provider and its " + what)
	}
	all, err := s.List(ctx)
	if err != nil {
		return nil, llmprovider.Model{}, err
	}
	for i := range all {
		p := &all[i]
		if p.ID.String() != providerID {
			continue
		}
		if !p.Enabled || p.APIKey == "" {
			return nil, llmprovider.Model{}, errs.New(errs.CodeUnavailable, "LLM provider "+p.Name+" is disabled or has no API key")
		}
		m, ok := p.Model(modelID)
		if !ok {
			return nil, llmprovider.Model{}, errs.InvalidArgument("model " + modelID + " is not offered by " + p.Name)
		}
		if capability == llmprovider.CapabilityEmbedding && !m.Embedding() {
			return nil, llmprovider.Model{}, errs.InvalidArgument("model " + modelID + " is not an embedding model (mark it as one on the Models page)")
		}
		if capability == llmprovider.CapabilityChat && !m.Chat() {
			return nil, llmprovider.Model{}, errs.InvalidArgument("model " + modelID + " is not a chat model")
		}
		return p, m, nil
	}
	return nil, llmprovider.Model{}, errs.NotFound("LLM provider " + providerID)
}

// resolveMemory returns the endpoint of one of the memory models. It fails
// with CodeUnavailable when that model is not chosen or no longer usable.
func (s *Service) resolveMemory(ctx context.Context, capability string) (vmm.ProviderConfig, error) {
	setting, err := s.Memory(ctx)
	if err != nil {
		return vmm.ProviderConfig{}, err
	}
	providerID, modelID := setting.ChatProviderID, setting.ChatModelID
	if capability == llmprovider.CapabilityEmbedding {
		providerID, modelID = setting.EmbeddingProviderID, setting.EmbeddingModelID
	}
	if modelID == "" {
		return vmm.ProviderConfig{}, errs.New(errs.CodeUnavailable, "no memory "+capability+" model is chosen (Admin → Memory models)")
	}
	p, m, err := s.memoryModel(ctx, providerID, modelID, capability)
	if err != nil {
		return vmm.ProviderConfig{}, errs.New(errs.CodeUnavailable, "the memory "+capability+" model is unavailable: "+err.Error())
	}
	baseURL := p.BaseURL
	if p.Kind == "vertex" || strings.Contains(baseURL, "aiplatform.googleapis.com") {
		baseURL = ResolveVertexURL(ctx, baseURL, p.APIKey)
	}
	return vmm.ProviderConfig{Kind: string(p.Kind), BaseURL: baseURL, APIKey: p.APIKey, Model: m.ID,
		ContextWindow: ContextWindow(m), InputPrice: m.InputPrice, OutputPrice: m.OutputPrice, OwnerID: p.OwnerID.String()}, nil
}

// ResolveMemoryChat is the endpoint of the model OpenViking extracts memories with.
func (s *Service) ResolveMemoryChat(ctx context.Context) (vmm.ProviderConfig, error) {
	return s.resolveMemory(ctx, llmprovider.CapabilityChat)
}

// ResolveMemoryEmbedding is the endpoint of the model OpenViking embeds memories with.
func (s *Service) ResolveMemoryEmbedding(ctx context.Context) (vmm.ProviderConfig, error) {
	return s.resolveMemory(ctx, llmprovider.CapabilityEmbedding)
}

// memoryView renders the setting for the admin panel: what is stored, what is
// in effect (and why not) and the models to pick from.
func (s *Service) memoryView(ctx context.Context) (map[string]any, error) {
	setting, err := s.Memory(ctx)
	if err != nil {
		return nil, err
	}
	all, err := s.List(ctx)
	if err != nil {
		return nil, err
	}
	providers := []map[string]any{}
	for i := range all {
		p := &all[i]
		if !p.Enabled || p.APIKey == "" {
			continue
		}
		chat, embedding := []llmprovider.Model{}, []llmprovider.Model{}
		for _, m := range modelsView(p) {
			if m.Disabled {
				continue
			}
			if m.Chat() {
				chat = append(chat, m)
			}
			if m.Embedding() {
				embedding = append(embedding, m)
			}
		}
		providers = append(providers, map[string]any{"id": p.ID.String(), "name": p.Name, "kind": p.Kind,
			"chat_models": chat, "embedding_models": embedding})
	}
	usable := func(capability string) (bool, string) {
		if _, err := s.resolveMemory(ctx, capability); err != nil {
			return false, err.Error()
		}
		return true, ""
	}
	chatOK, chatWhy := usable(llmprovider.CapabilityChat)
	embedOK, embedWhy := usable(llmprovider.CapabilityEmbedding)
	var status string
	switch {
	case chatOK && embedOK:
		status = "In effect: agents recall memories by meaning and learn from every conversation."
	case embedOK:
		status = "Partly in effect: memories are recalled by meaning, but nothing is learned from conversations (" + chatWhy + ")."
	case chatOK:
		status = "Partly in effect: memories are learned from conversations, but not recalled by meaning (" + embedWhy + ")."
	default:
		status = "Not in effect: agents keep and read their notes, but recall by meaning and learning need both models."
	}
	return map[string]any{
		"chat_provider_id": setting.ChatProviderID, "chat_model_id": setting.ChatModelID,
		"embedding_provider_id": setting.EmbeddingProviderID, "embedding_model_id": setting.EmbeddingModelID,
		"chat_active": chatOK, "embedding_active": embedOK, "active": chatOK && embedOK, "status": status,
		"server": openviking.FromEnv() != nil, "providers": providers,
	}, nil
}

// MemoryActions are the admin actions of the memory models setting.
func MemoryActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "llm", Name: "llm_memory_get", Summary: "Read the models the agents' memory works with",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := s.requireAdmin(req); err != nil {
					return nil, err
				}
				view, err := s.memoryView(ctx)
				if err != nil {
					return nil, err
				}
				return helper.JSON(view)
			}},
		helper.Action{Namespace: "llm", Name: "llm_memory_set", Summary: "Pick the chat and embedding models of the agents' memory",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := s.requireAdmin(req); err != nil {
					return nil, err
				}
				var in MemoryInput
				if err := helper.Decode(req, &in); err != nil {
					return nil, err
				}
				if _, err := s.SetMemory(ctx, in); err != nil {
					return nil, err
				}
				view, err := s.memoryView(ctx)
				if err != nil {
					return nil, err
				}
				return helper.JSON(view)
			}},
	}
}
