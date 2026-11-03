package bots

import (
	"context"
	"encoding/json"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/jsonpatch"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
	"github.com/aseman/aseman/plugins/actions/support/models/metadata"
)

const themePackMaxBytes = 512 * 1024

// CreateTheme deploys a KindTheme bot with no VM. Pack JSON is stored under
// static/theme.json.
func (s *Service) CreateTheme(ctx context.Context, owner identity.ID, name, description, packJSON string) (*bot.Bot, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil, errs.InvalidArgument("theme name required")
	}
	if err := validateThemePackJSON(packJSON); err != nil {
		return nil, err
	}
	node := s.K.NodeID()
	now := time.Now().UTC()
	accID, err := identity.New(node)
	if err != nil {
		return nil, err
	}
	walletID, err := identity.New(node)
	if err != nil {
		return nil, err
	}
	botID, err := identity.New(node)
	if err != nil {
		return nil, err
	}
	acc := &account.Account{
		Entity: entity.Entity{ID: accID, CreatedAt: now, UpdatedAt: now},
		Kind:   account.KindBot, Handle: name, Status: account.StatusActive, MetadataID: accID,
	}
	if err := s.R.CreateID(ctx, "accounts", accID, acc); err != nil {
		return nil, err
	}
	profile := map[string]any{"displayName": name, "type": "theme"}
	if description != "" {
		profile["description"] = description
	}
	meta := &metadata.Record{
		Owner: accID.String(), Tree: metadata.Tree{"profile": profile},
		PublicPaths: []string{"/profile"}, Version: 1, UpdatedAt: now,
	}
	if err := s.R.CreateID(ctx, "metadatas", accID, meta); err != nil {
		return nil, err
	}
	wal := &wallet.Wallet{ID: walletID, OwnerID: accID, Balance: 0, Locked: 0, UpdatedAt: now}
	if err := s.R.CreateID(ctx, "wallets", walletID, wal); err != nil {
		return nil, err
	}
	rec := &bot.Bot{
		Entity:    entity.Entity{ID: botID, CreatedAt: now, UpdatedAt: now},
		OwnerID:   owner,
		AccountID: accID,
		Name:      name,
		Kind:      bot.KindTheme,
		VMType:    "theme",
		Status:    bot.StatusStopped,
		ImageRef:  "theme",
	}
	if err := s.R.CreateID(ctx, "bots", botID, rec); err != nil {
		return nil, err
	}
	if err := s.PutEntity(ctx, owner, botID, bot.EntityThemePack, []byte(packJSON), "application/json"); err != nil {
		return nil, err
	}
	if description != "" {
		_ = s.M.Patch(ctx, accID, jsonpatch.Patch{{
			Op: "set", Path: "profile/description", Value: description,
		}})
	}
	s.L.Info("theme created", "bot_id", botID.String(), "owner", owner.String())
	return rec, nil
}

// UpdateThemePack replaces the pack JSON for a theme the caller owns.
func (s *Service) UpdateThemePack(ctx context.Context, caller, botID identity.ID, name, description, packJSON string) (*bot.Bot, error) {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return nil, err
	}
	if rec.Kind != bot.KindTheme {
		return nil, errs.InvalidArgument("not a theme")
	}
	if rec.OwnerID != caller {
		return nil, errs.Permission("only the theme owner can edit it")
	}
	if err := validateThemePackJSON(packJSON); err != nil {
		return nil, err
	}
	if err := s.PutEntity(ctx, caller, botID, bot.EntityThemePack, []byte(packJSON), "application/json"); err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	if name = strings.TrimSpace(name); name != "" {
		rec.Name = name
	}
	rec.UpdatedAt = now
	if err := s.R.Update(ctx, "bots", botID, rec); err != nil {
		return nil, err
	}
	if description != "" {
		_ = s.M.Patch(ctx, rec.AccountID, jsonpatch.Patch{{
			Op: "set", Path: "profile/description", Value: description,
		}})
	}
	return rec, nil
}

// ThemePackJSON loads static/theme.json for a theme bot.
func (s *Service) ThemePackJSON(ctx context.Context, botID identity.ID) (string, error) {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return "", err
	}
	if rec.Kind != bot.KindTheme {
		return "", errs.InvalidArgument("not a theme")
	}
	ent, err := s.GetEntity(ctx, botID, bot.EntityThemePack)
	if err != nil {
		return "", err
	}
	return string(ent.Value), nil
}

func validateThemePackJSON(raw string) error {
	if strings.TrimSpace(raw) == "" {
		return errs.InvalidArgument("theme pack required")
	}
	if utf8.RuneCountInString(raw) > themePackMaxBytes {
		return errs.InvalidArgument("theme pack too large")
	}
	var root map[string]any
	if err := json.Unmarshal([]byte(raw), &root); err != nil {
		return errs.InvalidArgument("theme pack must be JSON")
	}
	schema, _ := root["schema"].(string)
	if schema != "" && schema != "aseman.theme/v1" {
		return errs.InvalidArgument("unsupported theme schema")
	}
	meta, _ := root["meta"].(map[string]any)
	if meta == nil {
		return errs.InvalidArgument("theme meta required")
	}
	if strings.TrimSpace(str(meta["id"])) == "" || strings.TrimSpace(str(meta["name"])) == "" {
		return errs.InvalidArgument("theme meta.id and meta.name required")
	}
	tokens, _ := root["tokens"].(map[string]any)
	if tokens == nil {
		return errs.InvalidArgument("theme tokens required")
	}
	return nil
}

func str(v any) string {
	s, _ := v.(string)
	return s
}
