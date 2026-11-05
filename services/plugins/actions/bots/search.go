package bots

import (
	"context"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// SearchBots lists bots platform-wide (any owner), optionally filtered by one
// or more comma-separated kinds (agent, tool) and a name substring,
// newest first. This powers the Explore → global search so the whole platform's
// agents/tools are discoverable, not just the caller's own bots.
func (s *Service) SearchBots(ctx context.Context, query, kind string, limit, offset int) ([]bot.Bot, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	if offset < 0 {
		offset = 0
	}
	var kinds map[string]bool
	if kind != "" {
		kinds = map[string]bool{}
		for _, k := range strings.Split(kind, ",") {
			k = strings.TrimSpace(k)
			if k != "" {
				kinds[k] = true
			}
		}
	}
	var all []bot.Bot
	if err := s.R.List(ctx, "bots", database.Filter{OrderBy: "created_at", Asc: false}, &all); err != nil {
		return nil, err
	}
	q := strings.ToLower(strings.TrimSpace(query))
	var out []bot.Bot
	for _, b := range all {
		// Space sandboxes are computers, not apps — never surface them as tools.
		if b.IsSandbox() {
			continue
		}
		// Built-in Aseman (assistant / lead) is the personal Aseman chat, not a
		// separate New-chat peer.
		if b.IsBuiltin() {
			continue
		}
		if kinds != nil && !kinds[string(b.Kind)] {
			continue
		}
		if q != "" && !strings.Contains(strings.ToLower(b.Name), q) {
			continue
		}
		out = append(out, b)
	}
	if offset > len(out) {
		offset = len(out)
	}
	out = out[offset:]
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// botSearchAction implements bots.bot_search.
type botSearchAction struct{ s *Service }

func (a *botSearchAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "bot_search", Summary: "Search agents and apps across the whole platform"}
}
func (a *botSearchAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Query  string `json:"query,omitempty"`
		Kind   string `json:"kind,omitempty"` // agent | tool
		Limit  int    `json:"limit,omitempty"`
		Offset int    `json:"offset,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	limit, offset := in.Limit, in.Offset
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	list, err := a.s.SearchBots(ctx, in.Query, in.Kind, limit*4+offset+20, 0)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, limit)
	skipped := 0
	for i := range list {
		if !helper.SeesEntity(ctx, a.s.R, req.Caller.ID, list[i].PlatformID) {
			continue
		}
		if skipped < offset {
			skipped++
			continue
		}
		out = append(out, map[string]any{
			"id": list[i].ID.String(), "account_id": list[i].AccountID.String(), "name": list[i].Name,
			"kind": string(list[i].Kind), "vm_type": string(list[i].VMType),
			"status": string(list[i].Status), "owner_id": list[i].OwnerID.String(),
			"image_ref": list[i].ImageRef, "platform_id": list[i].PlatformID,
			"avatar": a.s.avatarOf(ctx, list[i].AccountID),
		})
		if h := a.s.humanoidOf(ctx, list[i].AccountID); h != nil {
			out[len(out)-1]["humanoid"] = h
		}
		if len(out) >= limit {
			break
		}
	}
	return helper.JSON(map[string]any{"bots": out})
}
