package bots

import (
	"context"
	"testing"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/memory"
	dbmodel "github.com/tradera/tradera/plugins/testutil"
)

func entityHarness(t *testing.T) (*Service, context.Context, identity.ID, identity.ID) {
	t.Helper()
	ad := memory.New(logger.Global())
	ctx := context.Background()
	for _, m := range dbmodel.Models() {
		if err := ad.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"node_private_key": "01010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101"}})
	r := &repo.Repo{DB: ad}
	s := NewService(k, r, logger.Global())
	owner, _ := identity.New(1)
	botID, _ := identity.New(1)
	if err := s.R.CreateID(ctx, "bots", botID, &bot.Bot{
		Entity: entity.Entity{ID: botID}, OwnerID: owner,
		Name: "b", Kind: bot.KindMiniapp, VMType: bot.VMTypeWASM, Status: bot.StatusRunning,
	}); err != nil {
		t.Fatal(err)
	}
	return s, ctx, owner, botID
}

func TestEntityStorageLifecycle(t *testing.T) {
	s, ctx, owner, botID := entityHarness(t)

	// Put + get under a contract key.
	if err := s.PutEntity(ctx, owner, botID, bot.EntityFrontend, []byte("bundle-src"), "text/plain"); err != nil {
		t.Fatal(err)
	}
	ent, err := s.GetEntity(ctx, botID, bot.EntityFrontend)
	if err != nil || string(ent.Value) != "bundle-src" {
		t.Fatalf("get entity: %v %q", err, string(ent.Value))
	}

	// Static file under a file-prefixed key (binary-safe bytes).
	if err := s.PutEntity(ctx, owner, botID, bot.EntityFileKey("logo.png"), []byte{0x89, 'P', 'N', 'G'}, "image/png"); err != nil {
		t.Fatal(err)
	}
	if !bot.IsEntityFile(bot.EntityFileKey("logo.png")) {
		t.Fatal("static key must be recognised as a file entity")
	}

	// List returns both keys.
	items, err := s.ListEntities(ctx, botID)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 {
		t.Fatalf("expected 2 entities, got %d", len(items))
	}

	// A non-owner cannot write.
	other, _ := identity.New(1)
	if err := s.PutEntity(ctx, other, botID, bot.EntityBackend, []byte("evil"), ""); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("expected permission error, got %v", err)
	}

	// Delete.
	if err := s.DeleteEntity(ctx, owner, botID, bot.EntityFrontend); err != nil {
		t.Fatal(err)
	}
	if _, err := s.GetEntity(ctx, botID, bot.EntityFrontend); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("expected not found after delete, got %v", err)
	}
}

func TestWidgetStoredInEntityStore(t *testing.T) {
	s, ctx, owner, botID := entityHarness(t)
	if _, err := s.SetWidget(ctx, owner, botID, `{"rows":[]}`); err != nil {
		t.Fatal(err)
	}
	if got := s.Widget(ctx, botID); got != `{"rows":[]}` {
		t.Fatalf("widget should come from the entity store, got %q", got)
	}
}
