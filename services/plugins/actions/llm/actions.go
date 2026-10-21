package llm

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/llm/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// AdminActions are the admin-namespace actions managing LLM providers. They
// register in the llm namespace; admin owns the legacy delegated aliases.
func AdminActions(s *Service) []api.Action {
	return []api.Action{
		&providersListAction{s: s}, &providerSetAction{s: s},
		&providerDeleteAction{s: s}, &kindsAction{s: s}, &importVercelAction{s: s},
	}
}

// CatalogActions are the actions any user may call: the agent creation form
// lists the enabled providers/models (no credentials) through them.
func CatalogActions(s *Service) []api.Action {
	return []api.Action{&catalogAction{s: s}}
}

// requireAdmin only accepts the node admin account (strict handle match).
func (s *Service) requireAdmin(req *api.ActionRequest) error {
	return helper.RequireNodeAdmin(context.Background(), s.R, req, s.K.Env()["admin_handle"])
}

// view renders a provider for the admin panel: the key is masked.
func view(p *llmprovider.Provider) map[string]any {
	return map[string]any{
		"id": p.ID.String(), "name": p.Name, "kind": p.Kind, "base_url": p.BaseURL,
		"enabled": p.Enabled, "is_default": p.IsDefault, "models": modelsView(p),
		"image_model": p.ImageModel, "image_price": p.ImagePrice,
		"has_key": p.APIKey != "", "key_preview": p.KeyPreview(),
		"owner_id": p.OwnerID.String(), "updated_at": p.UpdatedAt,
	}
}

// modelsView lists a provider's models with their capabilities as the node
// treats them, so the admin panel shows what is in effect.
func modelsView(p *llmprovider.Provider) []llmprovider.Model {
	out := []llmprovider.Model{}
	for _, m := range p.ParseModels() {
		out = append(out, m.WithCapabilities())
	}
	return out
}

type providersListAction struct{ s *Service }

func (a *providersListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "llm", Name: "llm_providers_list", Summary: "List LLM providers (keys masked)"}
}
func (a *providersListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	list, err := a.s.List(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(list))
	for i := range list {
		out = append(out, view(&list[i]))
	}
	return helper.JSON(map[string]any{"providers": out})
}

type providerSetAction struct{ s *Service }

func (a *providerSetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "llm", Name: "llm_provider_set", Summary: "Create or update an LLM provider (API key, models, token prices)"}
}
func (a *providerSetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	var in ProviderInput
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	p, err := a.s.Set(ctx, req.Caller.ID, in)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"provider": view(p)})
}

type providerDeleteAction struct{ s *Service }

func (a *providerDeleteAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "llm", Name: "llm_provider_delete", Summary: "Delete an LLM provider"}
}
func (a *providerDeleteAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	var in struct {
		ID string `json:"id"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.ID)
	if err != nil {
		return nil, errs.InvalidArgument("invalid provider id")
	}
	if err := a.s.Delete(ctx, id); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

type kindsAction struct{ s *Service }

func (a *kindsAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "llm", Name: "llm_kinds", Summary: "List the supported LLM provider kinds and default endpoints"}
}
func (a *kindsAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"kinds": llmprovider.Presets()})
}

type catalogAction struct{ s *Service }

func (a *catalogAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "llm", Name: "llm_models", Summary: "List the LLM providers and models agents can use, with token prices"}
}
func (a *catalogAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	list, err := a.s.Catalog(ctx)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"providers": list, "price_unit": "credits per 1M tokens"})
}

type importVercelAction struct{ s *Service }

func (a *importVercelAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "llm", Name: "llm_import_vercel", Summary: "Import Vercel AI Gateway's models into a Vercel provider at Vercel's price plus a markup"}
}
func (a *importVercelAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.requireAdmin(req); err != nil {
		return nil, err
	}
	var in struct {
		ProviderID string  `json:"provider_id"`
		Markup     float64 `json:"markup"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	res, err := a.s.ImportVercel(ctx, in.ProviderID, in.Markup)
	if err != nil {
		return nil, err
	}
	return helper.JSON(res)
}
