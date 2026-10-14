package spaces

import (
	"strings"
	"testing"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
)

// A tool without a generative frontend is not shown in one: the agent is told
// to present its result in Markdown, by the listing and by frontend_show.
func TestFrontendShowNeedsAGenerativeFrontend(t *testing.T) {
	s, ctx := messageToolHarness(t)
	spaceID := identity.ID{Node: 1, Entity: 99}
	botID := identity.ID{Node: 1, Entity: 7}
	record := bot.Bot{Entity: entity.Entity{ID: botID}, Name: "notes", Kind: bot.KindTool, VMType: bot.VMTypeMCP}
	if err := s.R.CreateID(ctx, "bots", botID, &record); err != nil {
		t.Fatal(err)
	}
	member := membership.Membership{Entity: entity.Entity{ID: identity.ID{Node: 1, Entity: 70}}, SpaceID: spaceID, MemberID: botID, Role: membership.RoleBot}
	if err := s.R.CreateID(ctx, "memberships", member.ID, &member); err != nil {
		t.Fatal(err)
	}
	tools, err := s.SpaceTools(ctx, spaceID, identity.ID{})
	if err != nil {
		t.Fatal(err)
	}
	listed := false
	for _, tool := range tools {
		if tool.BotID == botID.String() {
			listed = true
			if !strings.Contains(tool.Description, "present its results in Markdown") {
				t.Fatalf("listing: %q", tool.Description)
			}
		}
	}
	if !listed {
		t.Fatal("the tool is not listed")
	}
	_, err = s.showTool(ctx, spaceID, identity.ID{}, "tradera", `{"tool":"`+botID.String()+`","microtool":"search","args":{"q":"x"}}`)
	if err == nil || !strings.Contains(err.Error(), "Markdown") {
		t.Fatalf("a tool without a generative frontend: %v", err)
	}
	_, err = s.showTool(ctx, spaceID, identity.ID{}, "tradera", `{"tool":"nope"}`)
	if err == nil || !strings.Contains(err.Error(), "no tool of this space") {
		t.Fatalf("an unknown tool: %v", err)
	}
}
