package bots

import (
	"testing"
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
)

func TestSearchBotsPlatformWide(t *testing.T) {
	s, ctx, owner, _ := entityHarness(t)
	// Seed two more bots: one agent and one tool.
	agentID, _ := identity.New(1)
	now := time.Now().UTC()
	agent := &bot.Bot{
		Entity:  entity.Entity{ID: agentID, CreatedAt: now, UpdatedAt: now},
		OwnerID: owner, Name: "AlphaAgent", Kind: bot.KindAgent,
		VMType: bot.VMTypeDeepAgents, Status: bot.StatusRunning,
	}
	if err := s.R.CreateID(ctx, "bots", agentID, agent); err != nil {
		t.Fatal(err)
	}
	toolID, _ := identity.New(1)
	tool := &bot.Bot{
		Entity:  entity.Entity{ID: toolID, CreatedAt: now, UpdatedAt: now},
		OwnerID: owner, Name: "SigmaTool", Kind: bot.KindTool,
		VMType: bot.VMTypeDocker, Status: bot.StatusRunning,
	}
	if err := s.R.CreateID(ctx, "bots", toolID, tool); err != nil {
		t.Fatal(err)
	}

	// kind filter: agents only.
	agents, err := s.SearchBots(ctx, "", "agent", 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(agents) != 1 || agents[0].Name != "AlphaAgent" {
		t.Fatalf("agent search = %v", agents)
	}

	// comma-separated kinds (miniapp,tool) → the miniapp + tool bots.
	combos, err := s.SearchBots(ctx, "", "miniapp,tool", 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(combos) != 2 {
		t.Fatalf("miniapp,tool search = %v", combos)
	}

	// name substring filter + pagination.
	page1, err := s.SearchBots(ctx, "alpha", "", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(page1) != 1 || page1[0].Name != "AlphaAgent" {
		t.Fatalf("query page = %v", page1)
	}
	page2, err := s.SearchBots(ctx, "alpha", "", 1, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(page2) != 0 {
		t.Fatalf("expected empty second page, got %v", page2)
	}
}
