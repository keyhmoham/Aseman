package bots

import (
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
)

// A bot stored under the retired miniapp kind becomes a tool (an app).
func TestMigrateRetiredKinds(t *testing.T) {
	s, ctx, owner, _ := entityHarness(t)
	id, _ := identity.New(1)
	now := time.Now().UTC()
	old := &bot.Bot{
		Entity:  entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		OwnerID: owner, Name: "OldApp", Kind: bot.Kind("miniapp"),
		VMType: bot.VMTypeWASM, Status: bot.StatusRunning,
	}
	if err := s.R.CreateID(ctx, "bots", id, old); err != nil {
		t.Fatal(err)
	}
	s.migrateRetiredKinds(ctx)
	var got bot.Bot
	if err := s.R.Get(ctx, "bots", id, &got); err != nil {
		t.Fatal(err)
	}
	if got.Kind != bot.KindTool {
		t.Fatalf("kind = %q, want tool", got.Kind)
	}
}
