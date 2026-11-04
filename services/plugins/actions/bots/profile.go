package bots

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/market/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// BotProfile assembles the public-facing profile of a bot (agent, app or
// tool) from its persisted record, its account metadata (description), live VM
// usage, runtime entities and its marketplace listing when published.
func (s *Service) BotProfile(ctx context.Context, botID identity.ID) (map[string]any, error) {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return nil, err
	}
	ownerHandle := ""
	if rec.OwnerID != (identity.ID{}) {
		var acc account.Account
		if s.R.Get(ctx, "accounts", rec.OwnerID, &acc) == nil {
			ownerHandle = acc.Handle
		}
	}
	description, avatar := "", ""
	var humanoid map[string]any
	if rec.AccountID != (identity.ID{}) {
		if m, merr := s.M.Get(ctx, rec.AccountID); merr == nil && m != nil {
			if p, ok := m.Tree["profile"].(map[string]any); ok {
				if d, ok := p["description"].(string); ok {
					description = d
				}
				if h, ok := p["humanoid"].(map[string]any); ok {
					humanoid = h
				}
			}
			avatar = helper.TreeAvatar(m.Tree)
		}
	}
	res := map[string]any{}
	if p, perr := rec.ParseResources(); perr == nil && p != nil {
		res = map[string]any{"cpu": p.CPU, "memory_mb": p.Memory, "disk_mb": p.Disk, "max_runtime_sec": p.MaxRuntimeSec}
	}
	cost := map[string]any{}
	if c := s.costFor(ctx, rec); c != nil {
		cost = map[string]any{"per_minute": c.PerMinute, "per_call": c.PerCall, "image_cost": c.ImageCost,
			"cpu_per_min": c.CPUPerMin, "memory_per_gb_min": c.MemoryPerGBMin, "disk_per_gb_min": c.DiskPerGBMin}
	}
	usage := map[string]any{}
	if u, uerr := s.Usage(ctx, botID); uerr == nil {
		usage = map[string]any{
			"vm_id": u.VMID, "uptime_sec": u.UptimeSeconds,
			"tokens": u.NetworkInBytes, "cpu_used": u.CPUUsed, "memory_mb": u.MemoryUsedMB,
			"measured_at": u.MeasuredAt,
		}
	}
	// The agent's LLM backbone and the token prices users pay for it.
	llmInfo := map[string]any{}
	if rec.Kind == bot.KindAgent && bot.AgentVMType(rec.VMType) == bot.VMTypeHarness && s.LLM != nil {
		provider, model := AgentBackbone(rec.SpecYML)
		if p, m, lerr := s.LLM.Resolve(ctx, provider, model); lerr == nil {
			llmInfo = map[string]any{
				"provider_id": p.ID.String(), "provider": p.Name, "kind": p.Kind,
				"model": m.ID, "input_price": m.InputPrice, "output_price": m.OutputPrice,
				"price_unit": "credits per 1M tokens",
			}
		}
	}
	entities, _ := s.ListEntities(ctx, botID)
	entityKeys := make([]string, 0, len(entities))
	for _, e := range entities {
		entityKeys = append(entityKeys, e.Key)
	}
	listing := map[string]any{}
	var listings []market.Listing
	if s.R.List(ctx, "market", database.Filter{Equal: map[string]any{"bot_id": botID.String(), "status": string(market.StatusActive)}}, &listings) == nil && len(listings) > 0 {
		l := listings[0]
		listing = map[string]any{
			"listing_id": l.ID.String(), "name": l.Name, "description": l.Description,
			"price": l.Price, "category": l.Category, "installs": l.Installs,
			"type": string(l.Type),
		}
	}
	out := map[string]any{
		"id": rec.ID.String(), "account_id": rec.AccountID.String(),
		"name": rec.Name, "kind": string(rec.Kind), "vm_type": string(rec.VMType),
		"status": string(rec.Status), "image_ref": rec.ImageRef,
		"owner_id": rec.OwnerID.String(), "owner_handle": ownerHandle,
		"description": description, "avatar": avatar, "resources": res, "cost": cost,
		"usage": usage, "entities": entityKeys, "llm": llmInfo,
		"has_frontend": rec.Frontend != "" || rec.FrontendRef != "",
		"created_at":   rec.CreatedAt, "updated_at": rec.UpdatedAt,
		"listing": listing,
	}
	if humanoid != nil {
		out["humanoid"] = humanoid
	}
	return out, nil
}

// botProfileAction implements bots.bot_profile.
type botProfileAction struct{ s *Service }

func (a *botProfileAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "bot_profile", Summary: "Rich profile for an agent or app"}
}
func (a *botProfileAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Bot string `json:"bot"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, errs.InvalidArgument("invalid bot id")
	}
	profile, err := a.s.BotProfile(ctx, id)
	if err != nil {
		return nil, err
	}
	return helper.JSON(profile)
}
