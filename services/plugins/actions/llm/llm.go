// Package llm manages the LLM providers configured by the node admin (API
// keys, models and token prices). Agents pick one provider + model as their
// backbone; the langchain runtime resolves its client from here on every
// request and billing prices the agent's token consumption with the model's
// configured input/output prices, paying the key owner's wallet.
package llm

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/llm/dto"
	"github.com/tradera/tradera/plugins/actions/llm/models"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// model is the database model name of the providers table.
const model = "llm_providers"

// Kernel is the subset of the kernel the service needs.
type Kernel interface {
	NodeID() identity.NodeID
	Env() map[string]string
}

// Service manages LLM providers.
type Service struct {
	K Kernel
	R *repo.Repo
	L *logger.Logger
	// VercelURL overrides Vercel AI Gateway's model list (tests).
	VercelURL string
}

// NewService builds the service.
func NewService(k Kernel, r *repo.Repo, log *logger.Logger) *Service {
	return &Service{K: k, R: r, L: log.Named("llm")}
}

// ProviderInput is the admin form for creating/updating a provider. An empty
// APIKey on update keeps the stored key.
type ProviderInput struct {
	ID         string              `json:"id,omitempty"`
	Name       string              `json:"name"`
	Kind       llmprovider.Kind    `json:"kind"`
	BaseURL    string              `json:"base_url,omitempty"`
	APIKey     string              `json:"api_key,omitempty"`
	Enabled    *bool               `json:"enabled,omitempty"`
	IsDefault  bool                `json:"is_default,omitempty"`
	Models     []llmprovider.Model `json:"models"`
	ImageModel string              `json:"image_model,omitempty"`
	ImagePrice float64             `json:"image_price,omitempty"`
}

// List returns every provider, default first then by name.
func (s *Service) List(ctx context.Context) ([]llmprovider.Provider, error) {
	var out []llmprovider.Provider
	if err := s.R.List(ctx, model, database.Filter{}, &out); err != nil {
		return nil, err
	}
	for i := range out {
		if err := s.openProviderKey(&out[i]); err != nil {
			return nil, err
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].IsDefault != out[j].IsDefault {
			return out[i].IsDefault
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out, nil
}

// Get returns one provider by id.
func (s *Service) Get(ctx context.Context, id identity.ID) (*llmprovider.Provider, error) {
	var p llmprovider.Provider
	if err := s.R.Get(ctx, model, id, &p); err != nil {
		return nil, err
	}
	if err := s.openProviderKey(&p); err != nil {
		return nil, err
	}
	return &p, nil
}

// Set creates or updates a provider owned by [owner] (the admin setting the key).
func (s *Service) Set(ctx context.Context, owner identity.ID, in ProviderInput) (*llmprovider.Provider, error) {
	preset, ok := llmprovider.PresetFor(in.Kind)
	if !ok {
		return nil, errs.InvalidArgument("unknown provider kind " + string(in.Kind))
	}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		in.Name = preset.Name
	}
	in.BaseURL = strings.TrimRight(strings.TrimSpace(in.BaseURL), "/")
	if in.BaseURL == "" {
		in.BaseURL = preset.BaseURL
	}
	if in.BaseURL == "" {
		return nil, errs.InvalidArgument("base_url required for a custom provider")
	}
	models, err := cleanModels(in.Models)
	if err != nil {
		return nil, err
	}
	if in.ImagePrice < 0 {
		return nil, errs.InvalidArgument("image_price must not be negative")
	}
	now := time.Now().UTC()
	var p *llmprovider.Provider
	creating := strings.TrimSpace(in.ID) == ""
	if creating {
		if strings.TrimSpace(in.APIKey) == "" {
			return nil, errs.InvalidArgument("api_key required")
		}
		id, err := identity.New(s.K.NodeID())
		if err != nil {
			return nil, err
		}
		p = &llmprovider.Provider{Entity: entity.Entity{ID: id, CreatedAt: now}, Enabled: true}
	} else {
		id, err := identity.Parse(in.ID)
		if err != nil {
			return nil, errs.InvalidArgument("invalid provider id")
		}
		if p, err = s.Get(ctx, id); err != nil {
			return nil, err
		}
	}
	p.UpdatedAt = now
	p.OwnerID = owner
	p.Name = in.Name
	p.Kind = in.Kind
	p.BaseURL = in.BaseURL
	if k := strings.TrimSpace(in.APIKey); k != "" {
		p.APIKey = k
	}
	if in.Enabled != nil {
		p.Enabled = *in.Enabled
	}
	p.SetModels(models)
	p.ImageModel = strings.TrimSpace(in.ImageModel)
	p.ImagePrice = in.ImagePrice
	all, err := s.List(ctx)
	if err != nil {
		return nil, err
	}
	// The first provider becomes the default; setting a new default clears it
	// on the others.
	p.IsDefault = in.IsDefault || !hasDefault(all, p.ID)
	if p.IsDefault {
		for i := range all {
			if all[i].ID != p.ID && all[i].IsDefault {
				all[i].IsDefault = false
				all[i].UpdatedAt = now
				if err := s.saveProvider(ctx, &all[i], false); err != nil {
					return nil, err
				}
			}
		}
	}
	if creating {
		err = s.saveProvider(ctx, p, true)
	} else {
		err = s.saveProvider(ctx, p, false)
	}
	if err != nil {
		return nil, err
	}
	return p, nil
}

func hasDefault(all []llmprovider.Provider, except identity.ID) bool {
	for i := range all {
		if all[i].ID != except && all[i].IsDefault {
			return true
		}
	}
	return false
}

// cleanModels validates and de-duplicates a model list (it may be empty).
func cleanModels(in []llmprovider.Model) ([]llmprovider.Model, error) {
	seen := map[string]bool{}
	out := make([]llmprovider.Model, 0, len(in))
	for _, m := range in {
		m.ID = strings.TrimSpace(m.ID)
		m.Name = strings.TrimSpace(m.Name)
		if m.ID == "" {
			continue
		}
		if seen[m.ID] {
			return nil, errs.InvalidArgument("duplicate model " + m.ID)
		}
		if m.InputPrice < 0 || m.OutputPrice < 0 || negativeUnits(m.Units) {
			return nil, errs.InvalidArgument("model prices must not be negative")
		}
		caps, err := cleanCapabilities(m.ID, m.Capabilities)
		if err != nil {
			return nil, err
		}
		m.Capabilities = caps
		seen[m.ID] = true
		out = append(out, m)
	}
	// A provider can exist before it has models: they are added on the Models page.
	return out, nil
}

// cleanCapabilities validates a model's capabilities. A known decision model
// listed without any is a decision model (a known embedding model is
// recognized when read, see Model.WithCapabilities).
func cleanCapabilities(id string, in []string) ([]string, error) {
	var out []string
	seen := map[string]bool{}
	for _, c := range in {
		c = strings.ToLower(strings.TrimSpace(c))
		if c == "" || seen[c] {
			continue
		}
		known := false
		for _, k := range llmprovider.Capabilities {
			known = known || c == k
		}
		if !known {
			return nil, errs.InvalidArgument("unknown model capability " + c)
		}
		seen[c] = true
		out = append(out, c)
	}
	if len(out) == 0 && llmprovider.KnownDecisionModel(id) {
		out = []string{llmprovider.CapabilityDecision}
	}
	return out, nil
}

// Delete removes a provider. When it was the default, another enabled
// provider is promoted.
func (s *Service) Delete(ctx context.Context, id identity.ID) error {
	p, err := s.Get(ctx, id)
	if err != nil {
		return err
	}
	if err := s.R.Delete(ctx, model, id); err != nil {
		return err
	}
	if !p.IsDefault {
		return nil
	}
	all, err := s.List(ctx)
	if err != nil {
		return err
	}
	for i := range all {
		if all[i].Enabled {
			all[i].IsDefault = true
			all[i].UpdatedAt = time.Now().UTC()
			return s.saveProvider(ctx, &all[i], false)
		}
	}
	return nil
}

// provider resolves a provider reference: an id, a name or a kind. Empty
// means the default (or first enabled) provider. Only enabled providers with
// an API key resolve.
func (s *Service) provider(ctx context.Context, ref string) (*llmprovider.Provider, error) {
	all, err := s.List(ctx)
	if err != nil {
		return nil, err
	}
	usable := func(p *llmprovider.Provider) bool { return p.Enabled && p.APIKey != "" }
	ref = strings.TrimSpace(ref)
	if ref != "" {
		for i := range all {
			p := &all[i]
			if p.ID.String() == ref || strings.EqualFold(p.Name, ref) || string(p.Kind) == strings.ToLower(ref) {
				if !usable(p) {
					return nil, errs.New(errs.CodeUnavailable, "LLM provider "+p.Name+" is disabled")
				}
				return p, nil
			}
		}
		return nil, errs.NotFound("LLM provider " + ref)
	}
	for i := range all { // List orders the default first.
		if usable(&all[i]) {
			return &all[i], nil
		}
	}
	return nil, errs.New(errs.CodeUnavailable, "no LLM provider configured; the node admin must add one in the admin panel")
}

// Resolve returns the provider and model an agent runs on. An empty model
// selects the provider's first chat model; a model not offered by the
// provider, or one that cannot chat (a decision model), is rejected.
func (s *Service) Resolve(ctx context.Context, providerRef, modelID string) (*llmprovider.Provider, llmprovider.Model, error) {
	p, err := s.provider(ctx, providerRef)
	if err != nil {
		return nil, llmprovider.Model{}, err
	}
	models := p.ChatModels()
	if strings.TrimSpace(modelID) == "" {
		if len(models) == 0 {
			return nil, llmprovider.Model{}, errs.New(errs.CodeUnavailable, "LLM provider "+p.Name+" has no models")
		}
		return p, models[0], nil
	}
	if m, ok := p.Model(modelID); ok {
		if !m.Chat() {
			return nil, llmprovider.Model{}, errs.InvalidArgument("model " + modelID + " is a decision model: agents cannot run on it")
		}
		return p, m, nil
	}
	return nil, llmprovider.Model{}, errs.InvalidArgument("model " + modelID + " is not offered by " + p.Name)
}

// ResolveImage returns the provider used for image generation: the given
// provider when it has an image model, otherwise the default/first enabled
// provider that has one.
func (s *Service) ResolveImage(ctx context.Context, providerRef string) (*llmprovider.Provider, error) {
	if providerRef != "" {
		if p, err := s.provider(ctx, providerRef); err == nil && p.ImageModel != "" {
			return p, nil
		}
	}
	all, err := s.List(ctx)
	if err != nil {
		return nil, err
	}
	for i := range all {
		if all[i].Enabled && all[i].APIKey != "" && all[i].ImageModel != "" {
			return &all[i], nil
		}
	}
	return nil, errs.New(errs.CodeUnavailable, "no image generation model configured; the node admin must set one on an LLM provider")
}

// Price is the resolved pricing of an agent's backbone model and the account
// paid for its usage.
type Price = dto.Price

// PriceFor returns the pricing of a provider + model reference. A model no
// longer offered falls back to the provider's first model's prices.
func (s *Service) PriceFor(ctx context.Context, providerRef, modelID string) (Price, error) {
	p, m, err := s.Resolve(ctx, providerRef, modelID)
	if err != nil {
		p, err = s.provider(ctx, providerRef)
		if err != nil {
			return Price{}, err
		}
		models := p.ChatModels()
		if len(models) == 0 {
			return Price{}, errs.New(errs.CodeUnavailable, "LLM provider "+p.Name+" has no models")
		}
		m = models[0]
	}
	return Price{ProviderID: p.ID, Payee: p.OwnerID, InputPrice: m.InputPrice, OutputPrice: m.OutputPrice}, nil
}

// TokenCost prices token consumption: in×input/1M + out×output/1M, rounded up
// to whole credits so any priced usage costs at least one credit.

// CatalogEntry is a provider as offered to agent creators: no credentials.
type CatalogEntry struct {
	ID        string              `json:"id"`
	Name      string              `json:"name"`
	Kind      llmprovider.Kind    `json:"kind"`
	IsDefault bool                `json:"is_default"`
	Models    []llmprovider.Model `json:"models"`
	HasImages bool                `json:"has_images"`
}

// Catalog lists the enabled providers and the models agents can run on, with
// prices (decision models are the admin's to pick, never an agent backbone).
func (s *Service) Catalog(ctx context.Context) ([]CatalogEntry, error) {
	all, err := s.List(ctx)
	if err != nil {
		return nil, err
	}
	out := []CatalogEntry{}
	for i := range all {
		p := &all[i]
		if !p.Enabled || p.APIKey == "" {
			continue
		}
		out = append(out, CatalogEntry{ID: p.ID.String(), Name: p.Name, Kind: p.Kind,
			IsDefault: p.IsDefault, Models: p.ChatModels(), HasImages: p.ImageModel != ""})
	}
	return out, nil
}

// SeedIfEmpty registers a provider from static configuration (config file or
// environment) when none exists yet, so a node configured the old way keeps
// working and the admin can manage the key from the panel afterwards.
func (s *Service) SeedIfEmpty(ctx context.Context, owner identity.ID, in ProviderInput) (bool, error) {
	all, err := s.List(ctx)
	if err != nil {
		return false, err
	}
	if len(all) > 0 || strings.TrimSpace(in.APIKey) == "" {
		return false, nil
	}
	in.IsDefault = true
	if _, err := s.Set(ctx, owner, in); err != nil {
		return false, err
	}
	return true, nil
}

func negativeUnits(u *llmprovider.UnitPrices) bool {
	if u == nil {
		return false
	}
	for _, v := range u.SecondBy {
		if v < 0 {
			return true
		}
	}
	return u.Image < 0 || u.Second < 0 || u.Character < 0 || u.Search < 0
}
