package bots

import (
	"context"
	"encoding/base64"
	"mime"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// entityMime guesses a content type for a contract key / file extension.
func entityMime(key string) string {
	switch {
	case key == bot.EntityFrontend:
		return "text/plain"
	case strings.HasSuffix(key, ".json"):
		return "application/json"
	case strings.HasSuffix(key, ".yml") || strings.HasSuffix(key, ".yaml"):
		return "text/yaml"
	case strings.HasSuffix(key, ".md"):
		return "text/markdown"
	case strings.HasPrefix(key, bot.EntityStatic), strings.HasPrefix(key, bot.EntityAssets):
		if t := mime.TypeByExtension(filepath.Ext(key)); t != "" {
			return t
		}
	}
	return ""
}

// PutEntity stores a runtime entity (backend binary, spec, frontend script,
// static file, ...) for a bot. Only the bot owner or its bot account may write.
func (s *Service) PutEntity(ctx context.Context, caller, botID identity.ID, key string, value []byte, mime string) error {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return err
	}
	if rec.OwnerID != caller && rec.AccountID != caller {
		return errs.Permission("not the bot owner")
	}
	now := time.Now().UTC()
	var list []bot.Entity
	if err := s.R.List(ctx, "bot_entities", database.Filter{
		Equal: map[string]any{"bot_id": botID.String(), "key": key},
	}, &list); err != nil {
		return err
	}
	if len(list) > 0 {
		ent := &list[0]
		ent.Value = value
		ent.Mime = mime
		ent.Size = int64(len(value))
		ent.UpdatedAt = now
		return s.R.Update(ctx, "bot_entities", ent.ID, ent)
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	ent := &bot.Entity{
		Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		BotID:  botID, Key: key, Value: value, Mime: mime, Size: int64(len(value)),
	}
	return s.R.CreateID(ctx, "bot_entities", id, ent)
}

// GetEntity reads a runtime entity of a bot. Callers enforce authorization.
func (s *Service) GetEntity(ctx context.Context, botID identity.ID, key string) (*bot.Entity, error) {
	var list []bot.Entity
	if err := s.R.List(ctx, "bot_entities", database.Filter{
		Equal: map[string]any{"bot_id": botID.String(), "key": key},
	}, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, errs.NotFound("bot entity " + key)
	}
	return &list[0], nil
}

// ListEntities lists the runtime entities stored for a bot.
func (s *Service) ListEntities(ctx context.Context, botID identity.ID) ([]bot.Entity, error) {
	var out []bot.Entity
	if err := s.R.List(ctx, "bot_entities", database.Filter{
		Equal: map[string]any{"bot_id": botID.String()}, OrderBy: "created_at", Asc: false,
	}, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// DeleteEntity removes a runtime entity of a bot.
func (s *Service) DeleteEntity(ctx context.Context, caller, botID identity.ID, key string) error {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return err
	}
	if rec.OwnerID != caller && rec.AccountID != caller {
		return errs.Permission("not the bot owner")
	}
	ent, err := s.GetEntity(ctx, botID, key)
	if err != nil {
		return err
	}
	return s.R.Delete(ctx, "bot_entities", ent.ID)
}

// entityWire renders an entity for the JSON API. Text content is returned
// verbatim; binary content is base64-encoded.
func entityWire(e *bot.Entity) map[string]any {
	out := map[string]any{
		"bot_id": e.BotID.String(),
		"key":    e.Key,
		"mime":   e.Mime,
		"size":   e.Size,
	}
	if utf8.Valid(e.Value) {
		out["value"] = string(e.Value)
		out["encoding"] = "text"
	} else {
		out["value"] = base64.StdEncoding.EncodeToString(e.Value)
		out["encoding"] = "base64"
	}
	return out
}

// --- actions ---

type botEntityPutAction struct{ s *Service }

func (a *botEntityPutAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "entity_put", Summary: "Store a runtime entity (backend, spec, frontend, static file, ...) for a bot"}
}
func (a *botEntityPutAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Bot      string `json:"bot"`
		Key      string `json:"key"`
		Value    string `json:"value"`
		Mime     string `json:"mime,omitempty"`
		Encoding string `json:"encoding,omitempty"` // "base64" for binary content
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, errs.InvalidArgument("invalid bot id")
	}
	if in.Key == "" {
		return nil, errs.InvalidArgument("entity key required")
	}
	var value []byte
	if in.Encoding == "base64" {
		value, err = base64.StdEncoding.DecodeString(in.Value)
		if err != nil {
			return nil, errs.InvalidArgument("invalid base64 entity value")
		}
	} else {
		value = []byte(in.Value)
	}
	if err := a.s.PutEntity(ctx, req.Caller.ID, id, in.Key, value, in.Mime); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"bot_id": id.String(), "key": in.Key, "size": len(value), "ok": true})
}

type botEntityGetAction struct{ s *Service }

func (a *botEntityGetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "entity_get", Summary: "Read a runtime entity of a bot"}
}
func (a *botEntityGetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Bot string `json:"bot"`
		Key string `json:"key"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, errs.InvalidArgument("invalid bot id")
	}
	rec, err := a.s.GetBot(ctx, id)
	if err != nil {
		return nil, err
	}
	if rec.OwnerID != req.Caller.ID && rec.AccountID != req.Caller.ID {
		return nil, errs.Permission("not the bot owner")
	}
	ent, err := a.s.GetEntity(ctx, id, in.Key)
	if err != nil {
		return nil, err
	}
	return helper.JSON(entityWire(ent))
}

type botEntityListAction struct{ s *Service }

func (a *botEntityListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "entity_list", Summary: "List the runtime entities of a bot"}
}
func (a *botEntityListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
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
	rec, err := a.s.GetBot(ctx, id)
	if err != nil {
		return nil, err
	}
	if rec.OwnerID != req.Caller.ID && rec.AccountID != req.Caller.ID {
		return nil, errs.Permission("not the bot owner")
	}
	items, err := a.s.ListEntities(ctx, id)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(items))
	for i := range items {
		out = append(out, entityWire(&items[i]))
	}
	return helper.JSON(map[string]any{"bot_id": id.String(), "entities": out})
}

type botEntityDeleteAction struct{ s *Service }

func (a *botEntityDeleteAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "entity_delete", Summary: "Delete a runtime entity of a bot"}
}
func (a *botEntityDeleteAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Bot string `json:"bot"`
		Key string `json:"key"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, errs.InvalidArgument("invalid bot id")
	}
	if err := a.s.DeleteEntity(ctx, req.Caller.ID, id, in.Key); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"bot_id": id.String(), "key": in.Key, "ok": true})
}
