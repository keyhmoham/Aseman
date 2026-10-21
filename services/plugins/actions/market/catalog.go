package market

import (
	"context"
	"encoding/json"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	models "github.com/aseman/aseman/plugins/actions/market/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/metasvc"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"sort"
	"strings"
	"time"
)

func catalogActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "market", Name: "catalog", Summary: "Visible listings with bot descriptors", Handler: s.catalogAction},
		helper.Action{Namespace: "market", Name: "recommend", Summary: "Rank marketplace agents for a brief", Handler: s.recommendAction},
		helper.Action{Namespace: "market", Name: "approve", Summary: "Approve a market listing", Handler: s.approveAction},
		helper.Action{Namespace: "market", Name: "deny", Summary: "Decline a market listing", Handler: s.denyAction},
		helper.Action{Namespace: "market", Name: "stats", Summary: "Marketplace moderation counts", Handler: s.statsAction},
	}
}
func (s *Service) catalog(ctx context.Context, caller identity.ID, admin bool, status string) ([]map[string]any, error) {
	var rows []models.Listing
	if e := s.R.List(ctx, "market", database.Filter{OrderBy: "created_at", Asc: false}, &rows); e != nil {
		return nil, e
	}
	out := []map[string]any{}
	seen := map[string]bool{}
	for _, l := range rows {
		if l.Status != models.StatusActive && l.PublisherID != caller && !admin {
			continue
		}
		if status != "all" && status != "" && status != string(l.Status) {
			continue
		}
		rec, e := s.B.GetBot(ctx, l.BotID)
		if e != nil {
			continue
		}
		row := s.catalogBot(ctx, rec)
		row["listing"] = l
		row["status"] = l.Status
		row["category"] = l.Category
		// The listing's copy is a snapshot from publishing; the owner's current
		// description (the descriptor) wins so edits show up.
		if d, _ := row["description"].(string); d == "" && l.Description != "" {
			row["description"] = l.Description
		}
		out = append(out, row)
		seen[rec.ID.String()] = true
	}
	// The reserved orchestrator is built-in, always usable without publishing a
	// user-owned listing. It is the same bot attached by CreateSpace.
	var lead *bot.Bot
	if e := bridge.Invoke(ctx, s.K, "bots", "InstallAseman", []any{ctx}, &lead); e == nil && lead != nil && !seen[lead.ID.String()] {
		row := s.catalogBot(ctx, lead)
		row["builtin"] = true
		// The lead's @username is configurable (admin → Agents); "lead" is the default.
		if h, _ := row["handle"].(string); h == "" {
			row["handle"] = "lead"
		}
		row["status"] = models.StatusActive
		out = append(out, row)
	}
	// Include unpublished owned bots so a draft can be edited before publication.
	var bots []bot.Bot
	if e := s.R.List(ctx, "bots", database.Filter{Equal: map[string]any{"owner_id": caller.String()}}, &bots); e != nil {
		return nil, e
	}
	for i := range bots {
		rec := &bots[i]
		if seen[rec.ID.String()] || rec.Kind == bot.KindTool && strings.HasPrefix(rec.Name, "sbx-") {
			continue
		}
		row := s.catalogBot(ctx, rec)
		row["status"] = "draft"
		out = append(out, row)
	}
	return out, nil
}
func (s *Service) catalogBot(ctx context.Context, rec *bot.Bot) map[string]any {
	row := map[string]any{"bot": rec, "kind": rec.Kind, "description": "", "descriptor": map[string]any{}}
	// The price users pay: the bot's own rates, or the platform's for what it
	// leaves unset.
	var cost bot.CostModel
	if e := bridge.Invoke(ctx, s.K, "bots", "EffectiveCost", []any{ctx, rec.ID}, &cost); e == nil {
		row["cost"] = cost
	} else if c, e := rec.ParseCost(); e == nil {
		row["cost"] = c
	}
	var owner account.Account
	if s.R.Get(ctx, "accounts", rec.OwnerID, &owner) == nil {
		row["owner_handle"] = owner.Handle
	}
	m := metasvc.Service{K: s.K, R: s.R}
	if meta, e := m.View(ctx, identity.ID{}, rec.AccountID); e == nil {
		if d, ok := meta.Tree["descriptor"].(map[string]any); ok {
			row["descriptor"] = d
			row["handle"] = d["username"]
			row["description"] = d["description"]
		} else if p, ok := meta.Tree["profile"].(map[string]any); ok {
			row["description"] = p["description"]
		}
	}
	return row
}
func (s *Service) catalogAction(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireAuthenticated(req); e != nil {
		return nil, e
	}
	var in struct {
		Status string `json:"status"`
	}
	_ = helper.Decode(req, &in)
	admin := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]) == nil
	rows, e := s.catalog(ctx, req.Caller.ID, admin, in.Status)
	if e != nil {
		return nil, e
	}
	return helper.JSON(map[string]any{"items": rows})
}
func (s *Service) review(ctx context.Context, req *api.ActionRequest, status models.Status) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var in struct {
		Listing string `json:"listing"`
		Bot     string `json:"bot"`
		Reason  string `json:"reason"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	var l *models.Listing
	var e error
	if in.Listing != "" {
		id, err := identity.Parse(in.Listing)
		if err != nil {
			return nil, err
		}
		l, e = s.Get(ctx, id)
	} else {
		var rows []models.Listing
		e = s.R.List(ctx, "market", database.Filter{Equal: map[string]any{"bot_id": in.Bot}}, &rows)
		if e == nil && len(rows) > 0 {
			l = &rows[0]
		}
	}
	if e != nil {
		return nil, e
	}
	if l == nil {
		return nil, errs.NotFound("market listing")
	}
	l.Status = status
	l.ReviewReason = in.Reason
	l.UpdatedAt = time.Now().UTC()
	if e = s.R.Update(ctx, "market", l.ID, l); e != nil {
		return nil, e
	}
	return helper.JSON(map[string]any{"ok": true, "listing": l})
}
func (s *Service) approveAction(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	return s.review(ctx, req, models.StatusActive)
}
func (s *Service) denyAction(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	return s.review(ctx, req, models.StatusDenied)
}
func (s *Service) statsAction(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var rows []models.Listing
	if e := s.R.List(ctx, "market", database.Filter{}, &rows); e != nil {
		return nil, e
	}
	stats := map[string]int{}
	for _, r := range rows {
		stats[string(r.Status)]++
	}
	return helper.JSON(map[string]any{"stats": stats})
}
func (s *Service) recommendAction(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireAuthenticated(req); e != nil {
		return nil, e
	}
	var in struct {
		Brief     string `json:"brief"`
		MaxAgents int    `json:"max_agents"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	if strings.TrimSpace(in.Brief) == "" {
		return nil, errs.InvalidArgument("brief required")
	}
	rows, e := s.catalog(ctx, req.Caller.ID, false, string(models.StatusActive))
	if e != nil {
		return nil, e
	}
	type scored struct {
		row   map[string]any
		score int
	}
	ranked := []scored{}
	words := strings.Fields(strings.ToLower(in.Brief))
	for _, r := range rows {
		b := r["bot"].(*bot.Bot)
		if b.Kind != bot.KindAgent {
			continue
		}
		raw, _ := json.Marshal(r["descriptor"])
		hay := strings.ToLower(b.Name + " " + string(raw))
		score := 0
		for _, w := range words {
			if len(w) > 2 && strings.Contains(hay, w) {
				score++
			}
		}
		if r["builtin"] == true {
			score += 100000
		}
		ranked = append(ranked, scored{r, score})
	}
	sort.SliceStable(ranked, func(i, j int) bool { return ranked[i].score > ranked[j].score })
	max := in.MaxAgents
	if max <= 0 || max > 4 {
		max = 4
	}
	picks := []map[string]any{}
	for i, r := range ranked {
		if i >= max {
			break
		}
		b := r.row["bot"].(*bot.Bot)
		picks = append(picks, map[string]any{"bot_id": b.ID.String(), "name": b.Name, "reason": "Selected from the available team for this project", "score": r.score})
	}
	return helper.JSON(map[string]any{"picks": picks, "source": "deterministic"})
}

func (s *Service) publisherIsAdmin(ctx context.Context, id identity.ID) bool {
	var a account.Account
	// An administrator is one by role, or the account named after the node
	// (the same rule as everywhere else: helper.RequireNodeAdmin). Knowing
	// only the latter sent an admin's own listings to review.
	return s.R.Get(ctx, "accounts", id, &a) == nil && a.Kind == account.KindUser && a.Status == account.StatusActive &&
		(a.Role == "admin" || a.Handle == s.K.Env()["admin_handle"])
}
