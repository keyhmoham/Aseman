// Package themes owns create/apply/active flows for installable UI theme packs.
package themes

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/market/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	themesmodel "github.com/aseman/aseman/plugins/actions/themes/models"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Service implements theme create / apply / active.
type Service struct {
	K api.Kernel
	R *repo.Repo
	L *logger.Logger
}

// NewService builds the themes service.
func NewService(k api.Kernel, r *repo.Repo, log *logger.Logger) *Service {
	return &Service{K: k, R: r, L: log.Named("themes")}
}

// Create makes a theme bot and optionally publishes it to the market.
func (s *Service) Create(ctx context.Context, owner identity.ID, name, description, packJSON string, publish bool) (themeID, listingID identity.ID, status string, err error) {
	var rec *bot.Bot
	if err = bridge.Invoke(ctx, s.K, "bots", "CreateTheme", []any{ctx, owner, name, description, packJSON}, &rec); err != nil {
		return
	}
	themeID = rec.ID
	status = "draft"
	if !publish {
		return
	}
	var listing *market.Listing
	err = bridge.Invoke(ctx, s.K, "market", "Publish", []any{
		ctx, owner, themeID, market.ItemTheme, name, description, int64(0), "design", "",
	}, &listing)
	if err != nil {
		return
	}
	listingID = listing.ID
	status = string(listing.Status)
	return
}

// Edit updates pack JSON for an owned theme.
func (s *Service) Edit(ctx context.Context, caller, themeID identity.ID, name, description, packJSON string) error {
	var rec *bot.Bot
	return bridge.Invoke(ctx, s.K, "bots", "UpdateThemePack", []any{ctx, caller, themeID, name, description, packJSON}, &rec)
}

// PackJSON returns the pack for a theme bot.
func (s *Service) PackJSON(ctx context.Context, themeID identity.ID) (string, error) {
	var raw string
	err := bridge.Invoke(ctx, s.K, "bots", "ThemePackJSON", []any{ctx, themeID}, &raw)
	return raw, err
}

// ApplyFromListing installs a marketplace theme onto the user.
func (s *Service) ApplyFromListing(ctx context.Context, user, listingID identity.ID) error {
	var listing *market.Listing
	if err := bridge.Invoke(ctx, s.K, "market", "Get", []any{ctx, listingID}, &listing); err != nil {
		return err
	}
	if listing.Type != market.ItemTheme {
		return errs.InvalidArgument("listing is not a theme")
	}
	if listing.Status != market.StatusActive {
		return errs.Conflict("listing is not active")
	}
	raw, err := s.PackJSON(ctx, listing.BotID)
	if err != nil {
		return err
	}
	return s.apply(ctx, user, listing.BotID, listingID, raw)
}

// ApplyTheme applies a theme bot the user owns (or any readable theme pack).
func (s *Service) ApplyTheme(ctx context.Context, user, themeID identity.ID) error {
	raw, err := s.PackJSON(ctx, themeID)
	if err != nil {
		return err
	}
	return s.apply(ctx, user, themeID, identity.ID{}, raw)
}

func (s *Service) apply(ctx context.Context, user, themeID, listingID identity.ID, packJSON string) error {
	now := time.Now().UTC()
	var existing []themesmodel.ActiveTheme
	if err := s.R.List(ctx, "user_themes", database.Filter{
		Equal: map[string]any{"user_id": user.String()},
		Limit: 1,
	}, &existing); err != nil {
		return err
	}
	if len(existing) > 0 {
		row := &existing[0]
		row.ThemeID = themeID
		row.ListingID = listingID
		row.PackJSON = packJSON
		row.Touch()
		return s.R.Update(ctx, "user_themes", row.ID, row)
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	row := &themesmodel.ActiveTheme{
		Entity:    entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		UserID:    user,
		ThemeID:   themeID,
		ListingID: listingID,
		PackJSON:  packJSON,
	}
	return s.R.CreateID(ctx, "user_themes", id, row)
}

// Active returns the legacy account-level applied theme row, if any.
//
// Theme look for a device is session-scoped (auth session metadata
// theme/theming). A new session starts with an empty tree and must not
// inherit this row — clients hydrate from session metadata, not here.
// This remains for themes.apply → themes.active in the same install flow.
func (s *Service) Active(ctx context.Context, user identity.ID) (*themesmodel.ActiveTheme, error) {
	var existing []themesmodel.ActiveTheme
	if err := s.R.List(ctx, "user_themes", database.Filter{
		Equal: map[string]any{"user_id": user.String()},
		Limit: 1,
	}, &existing); err != nil {
		return nil, err
	}
	if len(existing) == 0 {
		return nil, nil
	}
	return &existing[0], nil
}

// Clear removes the user's applied theme (client falls back to builtin Sky).
func (s *Service) Clear(ctx context.Context, user identity.ID) error {
	var existing []themesmodel.ActiveTheme
	if err := s.R.List(ctx, "user_themes", database.Filter{
		Equal: map[string]any{"user_id": user.String()},
		Limit: 5,
	}, &existing); err != nil {
		return err
	}
	for i := range existing {
		if err := s.R.Delete(ctx, "user_themes", existing[i].ID); err != nil {
			return err
		}
	}
	return nil
}

// Get is used by market.Get style bridges when needed.
func (s *Service) Get(ctx context.Context, id identity.ID) (*themesmodel.ActiveTheme, error) {
	row := &themesmodel.ActiveTheme{}
	if err := s.R.Get(ctx, "user_themes", id, row); err != nil {
		return nil, err
	}
	return row, nil
}
