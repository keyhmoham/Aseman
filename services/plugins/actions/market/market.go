// Package market implements the market namespace: publishing, discovering and
// installing agents and apps. A listing wraps a bot VM; installing adds the
// underlying bot to a workspace so its members can use it.
package market

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/market/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/metasvc"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// SpaceInstaller is the subset of the spaces service used to add an installed
// bot to a workspace.
type SpaceInstaller interface {
	AddBot(ctx context.Context, actor, spaceID, roomID, botID identity.ID) error
}

// BotLoader loads a bot record (implemented by the bots service).
type BotLoader interface {
	GetBot(ctx context.Context, id identity.ID) (*bot.Bot, error)
}

// Service implements marketplace operations.
type Service struct {
	K api.Kernel
	R *repo.Repo
	B BotLoader
	S SpaceInstaller
	L *logger.Logger
}

// Bootstrap turns listings stored under the retired "miniapp" type into
// tool listings: an app is a tool, whatever it was published as.
func (s *Service) Bootstrap(ctx context.Context) error {
	var old []market.Listing
	if err := s.R.List(ctx, "market", database.Filter{Equal: map[string]any{"type": "miniapp"}}, &old); err != nil {
		return nil
	}
	for i := range old {
		old[i].Type = market.ItemTool
		if err := s.R.Update(ctx, "market", old[i].ID, &old[i]); err != nil {
			s.L.Warn("could not migrate an app listing", "listing", old[i].ID.String(), "error", err)
		}
	}
	return nil
}

// NewService builds the market service.
func NewService(k api.Kernel, r *repo.Repo, bots BotLoader, spaces SpaceInstaller, log *logger.Logger) *Service {
	return &Service{K: k, R: r, B: bots, S: spaces, L: log.Named("market")}
}

// Publish creates (or refreshes) a listing for a bot owned by the caller.
func (s *Service) Publish(ctx context.Context, publisher identity.ID, botID identity.ID, itemType market.ItemType, name, description string, price int64, category, imageRef string) (*market.Listing, error) {
	rec, err := s.B.GetBot(ctx, botID)
	if err != nil {
		return nil, errs.NotFound("bot not found")
	}
	if rec.OwnerID != publisher {
		return nil, errs.Permission("only the bot owner can publish it")
	}
	kind := rec.Kind
	if kind == "" {
		kind = bot.KindAgent
	}
	switch itemType {
	case market.ItemAgent:
		// Agents may run on any VM, but default to langchain.
	case market.ItemTool:
		if rec.Kind != bot.KindTool {
			return nil, errs.InvalidArgument("app listings require an app")
		}
		if rec.IsSandbox() {
			return nil, errs.InvalidArgument("sandbox instances cannot be listed as apps")
		}
	case market.ItemTheme:
		if rec.Kind != bot.KindTheme {
			return nil, errs.InvalidArgument("theme listings require a theme pack")
		}
	default:
		return nil, errs.InvalidArgument("type must be agent, tool, or theme")
	}
	if name == "" {
		name = rec.Name
	}
	now := time.Now().UTC()
	// Reuse an existing listing for the same bot if present.
	var existing []market.Listing
	if err := s.R.List(ctx, "market", database.Filter{
		Equal: map[string]any{"bot_id": botID.String(), "publisher_id": publisher.String()},
	}, &existing); err == nil && len(existing) > 0 {
		l := &existing[0]
		l.Type = itemType
		l.Name = name
		l.Description = description
		l.Price = price
		l.Category = category
		l.ImageRef = imageRef
		l.Publish()
		if !s.publisherIsAdmin(ctx, publisher) {
			l.Status = market.StatusPending
		}
		if err := s.R.Update(ctx, "market", l.ID, l); err != nil {
			return nil, err
		}
		s.L.Info("listing updated", "listing", l.ID.String(), "bot", botID.String())
		return l, nil
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	l := &market.Listing{
		Entity:      entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		PublisherID: publisher, BotID: botID, Type: itemType,
		Name: name, Description: description, Price: price,
		Category: category, ImageRef: imageRef,
		Status: market.StatusActive,
	}
	if !s.publisherIsAdmin(ctx, publisher) {
		l.Status = market.StatusPending
	}
	if err := s.R.CreateID(ctx, "market", id, l); err != nil {
		return nil, err
	}
	s.L.Info("listing published", "listing", id.String(), "bot", botID.String(), "type", itemType)
	return l, nil
}

// Unpublish hides a listing (owner only).
func (s *Service) Unpublish(ctx context.Context, caller identity.ID, listingID identity.ID) error {
	l, err := s.Get(ctx, listingID)
	if err != nil {
		return err
	}
	if l.PublisherID != caller && !s.publisherIsAdmin(ctx, caller) {
		return errs.Permission("only the publisher can unpublish")
	}
	l.Unpublish()
	return s.R.Update(ctx, "market", listingID, l)
}

// Get loads a listing.
func (s *Service) Get(ctx context.Context, id identity.ID) (*market.Listing, error) {
	l := &market.Listing{}
	if err := s.R.Get(ctx, "market", id, l); err != nil {
		return nil, err
	}
	return l, nil
}

// List returns active listings, optionally filtered by type, category or query.
// viewer scopes results to bots that person may see across sub-platforms.
func (s *Service) List(ctx context.Context, viewer identity.ID, itemType string, category, query string, limit, offset int) ([]market.Listing, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	f := database.Filter{
		Equal:   map[string]any{"status": string(market.StatusActive)},
		OrderBy: "created_at", Asc: false,
	}
	if itemType != "" {
		f.Equal["type"] = itemType
	}
	if category != "" {
		f.Equal["category"] = category
	}
	var out []market.Listing
	if err := s.R.List(ctx, "market", f, &out); err != nil {
		return nil, err
	}
	kept := out[:0]
	for i := range out {
		if query != "" && !containsFold(out[i].Name, query) && !containsFold(out[i].Description, query) {
			continue
		}
		if !viewer.IsZero() && !s.listingVisible(ctx, viewer, &out[i]) {
			continue
		}
		kept = append(kept, out[i])
	}
	out = kept
	if offset > len(out) {
		offset = len(out)
	}
	out = out[offset:]
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// listingVisible reports whether the listed bot lives on a platform viewer may see.
func (s *Service) listingVisible(ctx context.Context, viewer identity.ID, l *market.Listing) bool {
	if s.B == nil || l == nil {
		return true
	}
	rec, err := s.B.GetBot(ctx, l.BotID)
	if err != nil || rec == nil {
		return false
	}
	return helper.SeesEntity(ctx, s.R, viewer, rec.PlatformID)
}

// MyListings returns listings published by the caller.
func (s *Service) MyListings(ctx context.Context, publisher identity.ID) ([]market.Listing, error) {
	var out []market.Listing
	if err := s.R.List(ctx, "market", database.Filter{
		Equal:   map[string]any{"publisher_id": publisher.String()},
		OrderBy: "created_at", Asc: false, Limit: 100,
	}, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// Install records an install and, when a target space/room is given, adds the
// bot to that workspace so its members can use it. Theme listings apply the
// pack to the installer's account instead of adding a space bot.
func (s *Service) Install(ctx context.Context, installer identity.ID, listingID identity.ID, spaceID, roomID identity.ID) (*market.Listing, error) {
	l, err := s.Get(ctx, listingID)
	if err != nil {
		return nil, err
	}
	if !s.listingVisible(ctx, installer, l) {
		return nil, errs.NotFound("listing")
	}
	if l.Status != market.StatusActive {
		return nil, errs.Conflict("listing is not active")
	}
	if l.Type == market.ItemTheme {
		if err := applyThemeListing(ctx, s.K, installer, listingID); err != nil {
			return nil, err
		}
	} else if !spaceID.IsZero() {
		if err := s.S.AddBot(ctx, installer, spaceID, roomID, l.BotID); err != nil {
			return nil, err
		}
	}
	l.Installed()
	if err := s.R.Update(ctx, "market", listingID, l); err != nil {
		return nil, err
	}
	s.L.Info("listing installed", "listing", listingID.String(), "by", installer.String(), "space", spaceID.String())
	return l, nil
}

func containsFold(haystack, needle string) bool {
	if needle == "" {
		return true
	}
	haystack, needle = stringsFold(haystack), stringsFold(needle)
	return len(needle) > 0 && len(haystack) >= len(needle) && indexFold(haystack, needle) >= 0
}

func stringsFold(s string) string {
	b := []byte(s)
	for i := range b {
		if b[i] >= 'A' && b[i] <= 'Z' {
			b[i] += 'a' - 'A'
		}
	}
	return string(b)
}

func indexFold(s, sub string) int {
	n := len(sub)
	for i := 0; i+n <= len(s); i++ {
		if s[i:i+n] == sub {
			return i
		}
	}
	return -1
}

// Detail is a listing joined with its bot for marketplace cards.
type Detail struct {
	market.Listing
	Bot *bot.Bot `json:"bot"`
	// The listed bot's picture, "" when it has none.
	Avatar string `json:"avatar"`
}

// DetailFor returns a listing joined with the underlying bot record.
func (s *Service) DetailFor(ctx context.Context, id identity.ID) (*Detail, error) {
	l, err := s.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	rec, err := s.B.GetBot(ctx, l.BotID)
	if err != nil {
		rec = nil
	}
	return &Detail{Listing: *l, Bot: rec, Avatar: s.AvatarOf(ctx, l.BotID)}, nil
}

// AvatarOf is the picture of the listed bot, "" when it has none.
func (s *Service) AvatarOf(ctx context.Context, botID identity.ID) string {
	if s.B == nil {
		return ""
	}
	rec, err := s.B.GetBot(ctx, botID)
	if err != nil || rec == nil || rec.AccountID.IsZero() {
		return ""
	}
	m, err := (&metasvc.Service{K: s.K, R: s.R}).Get(ctx, rec.AccountID)
	if err != nil || m == nil {
		return ""
	}
	return helper.TreeAvatar(m.Tree)
}
