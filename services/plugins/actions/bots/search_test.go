package bots

import (
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
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

	// comma-separated kinds (agent,tool) → the agent and both apps.
	combos, err := s.SearchBots(ctx, "", "agent,tool", 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(combos) != 3 {
		t.Fatalf("agent,tool search = %v", combos)
	}

	// A space sandbox must never appear as an app in search results.
	sbxID, _ := identity.New(1)
	sbx := &bot.Bot{
		Entity:  entity.Entity{ID: sbxID, CreatedAt: now, UpdatedAt: now},
		OwnerID: owner, Name: "sbx-space1", Kind: bot.KindTool,
		VMType: bot.VMTypeContainer, Status: bot.StatusRunning,
	}
	if err := s.R.CreateID(ctx, "bots", sbxID, sbx); err != nil {
		t.Fatal(err)
	}
	tools, err := s.SearchBots(ctx, "", "tool", 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, b := range tools {
		if b.IsSandbox() {
			t.Fatalf("sandbox surfaced as app: %+v", b)
		}
	}

	// Built-in Aseman is the personal Aseman chat, not a New-chat peer.
	assistID, _ := identity.New(1)
	assist := &bot.Bot{
		Entity:  entity.Entity{ID: assistID, CreatedAt: now, UpdatedAt: now},
		OwnerID: owner, Name: "Aseman", Kind: bot.KindAgent,
		VMType: bot.VMTypeDeepAgents, Status: bot.StatusRunning, ImageRef: bot.BuiltinChatImage,
	}
	if err := s.R.CreateID(ctx, "bots", assistID, assist); err != nil {
		t.Fatal(err)
	}
	agentsAfter, err := s.SearchBots(ctx, "", "agent", 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, b := range agentsAfter {
		if b.IsBuiltin() {
			t.Fatalf("builtin Aseman surfaced in search: %+v", b)
		}
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
