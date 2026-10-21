package spaces

import (
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Every tool's listing tells agents to show results with frontend_show; a
// tool the node cannot reach (no microtools, no frontend) has nothing to
// build an interface from, and the agent falls back to Markdown.
func TestFrontendShowNeedsSomethingToBuildFrom(t *testing.T) {
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
			if !strings.Contains(tool.Description, "frontend_show") || !strings.Contains(tool.Description, "designed for the person's request") {
				t.Fatalf("listing: %q", tool.Description)
			}
		}
	}
	if !listed {
		t.Fatal("the tool is not listed")
	}
	_, err = s.showTool(ctx, spaceID, identity.ID{}, "aseman", `{"tool":"`+botID.String()+`","microtool":"search","args":{"q":"x"}}`)
	if err == nil || !strings.Contains(err.Error(), "Markdown") {
		t.Fatalf("a tool without microtools: %v", err)
	}
	_, err = s.showTool(ctx, spaceID, identity.ID{}, "aseman", `{"tool":"nope"}`)
	if err == nil || !strings.Contains(err.Error(), "no tool of this space") {
		t.Fatalf("an unknown tool: %v", err)
	}
}

// Which frontend a desk window shows, by what the tool has and what is shown.
func TestDeskFrontend(t *testing.T) {
	result := DeskOp{Op: "open", Microtool: "report", Args: map[string]any{"city": "NY"}}
	itself := DeskOp{Op: "open"}
	for _, c := range []struct {
		own  string
		op   DeskOp
		want string
	}{
		{"generative", result, "generative"}, // the tool's own, on the result
		{"static", result, DeskAutoFrontend}, // a static program cannot take a result
		{"", result, DeskAutoFrontend},       // nothing of its own: generated
		{"generative", itself, "generative"}, // cached, or generated the first time
		{"static", itself, "static"},         // opened and run as it is
		{"", itself, DeskAutoFrontend},
	} {
		if got := deskFrontend(c.own, c.op); got != c.want {
			t.Errorf("own %q, result %v: %q, want %q", c.own, c.op.Microtool != "", got, c.want)
		}
	}
}

func TestAppUI(t *testing.T) {
	tool := &vmm.Tool{Commands: []vmm.ToolCommand{{Name: "create_view", UI: "ui://excalidraw/mcp-app.html"}, {Name: "read_me"}}}
	if appUI(tool, "create_view") != "ui://excalidraw/mcp-app.html" || appUI(tool, "read_me") != "" || appUI(tool, "") != "" {
		t.Fatal("appUI")
	}
}
