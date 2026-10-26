package bots

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/jsonpatch"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// SetWidget stores the desk-widget DSL of a bot in the entity store
// (widget_dsl) and mirrors it on account metadata for room widget polls.
func (s *Service) SetWidget(ctx context.Context, caller, botID identity.ID, dsl string) (*bot.Bot, error) {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return nil, err
	}
	if rec.OwnerID != caller && rec.AccountID != caller {
		return nil, errs.Permission("not the bot owner")
	}
	if err := s.PutEntity(ctx, caller, botID, bot.EntityWidget, []byte(dsl), ""); err != nil {
		return nil, err
	}
	_ = s.M.Patch(ctx, rec.AccountID, jsonpatch.Patch{{
		Op: "set", Path: "widget/dsl", Value: dsl,
	}})
	return rec, nil
}

// Widget returns the desk-widget DSL of a bot, or "" when unset.
func (s *Service) Widget(ctx context.Context, botID identity.ID) string {
	if ent, err := s.GetEntity(ctx, botID, bot.EntityWidget); err == nil && len(ent.Value) > 0 {
		return string(ent.Value)
	}
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return ""
	}
	m, err := s.M.Get(ctx, rec.AccountID)
	if err != nil || m == nil {
		return ""
	}
	node, ok := m.Tree["widget"].(map[string]any)
	if !ok {
		return ""
	}
	dsl, _ := node["dsl"].(string)
	return dsl
}

type botWidgetSetAction struct{ s *Service }

func (a *botWidgetSetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "widget_set", Summary: "Set the desk-widget DSL an app shows on room desks"}
}
func (a *botWidgetSetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Bot string `json:"bot"`
		Dsl string `json:"dsl"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, errs.InvalidArgument("invalid bot id")
	}
	if _, err := a.s.SetWidget(ctx, req.Caller.ID, id, in.Dsl); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"bot_id": id.String(), "ok": true})
}

type botWidgetGetAction struct{ s *Service }

func (a *botWidgetGetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "widget_get", Summary: "Get the stored desk-widget DSL of an app"}
}
func (a *botWidgetGetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
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
	return helper.JSON(map[string]any{"bot_id": id.String(), "dsl": a.s.Widget(ctx, id)})
}
