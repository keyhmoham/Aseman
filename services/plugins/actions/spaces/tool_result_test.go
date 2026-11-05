package spaces

import (
	"context"
	"sort"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/models/execution"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

type failingToolBots struct {
	BotPort
	calls *int
}

func (f failingToolBots) EnsureVM(context.Context, *bot.Bot) error {
	*f.calls++
	return errs.New(errs.CodeUnavailable, "custom tool backend unavailable")
}

func TestCustomToolErrorsAreReturnedAuditedAndNeverReplayed(t *testing.T) {
	s, ctx := fileToolHarness(t)
	space, err := s.CreateSpace(ctx, identity.ID{Node: 1, Entity: 1}, "tool failures", "")
	if err != nil {
		t.Fatal(err)
	}
	account := addDevBotMember(t, s, ctx, space.ID)
	var records []bot.Bot
	if err := s.R.List(ctx, "bots", database.Filter{Equal: map[string]any{"account_id": account.String()}}, &records); err != nil {
		t.Fatal(err)
	}
	record := records[0]
	record.Kind = bot.KindTool
	if err := s.R.Update(ctx, "bots", record.ID, &record); err != nil {
		t.Fatal(err)
	}
	calls := 0
	s.Bots = failingToolBots{BotPort: s.Bots, calls: &calls}
	ctx = vmm.WithExecution(ctx, vmm.Execution{SpaceID: space.ID.String(), RunID: "test-run", StepID: "0", ToolCallID: "one-operation"})
	if _, err := s.ToolDispatch(ctx, space.ID.String(), "worker", "tool_dev", `{"input":"perform task"}`); errs.CodeOf(err) != errs.CodeUnavailable {
		t.Fatalf("custom tool error swallowed: %v", err)
	}
	var events []execution.Event
	if err := s.R.List(ctx, "execution_events", database.Filter{}, &events); err != nil || len(events) != 1 || events[0].Status != "failed" {
		t.Fatalf("events=%+v err=%v", events, err)
	}
	if !strings.Contains(events[0].Result, "UNAVAILABLE") {
		t.Fatalf("audit marked failure as success: %q", events[0].Result)
	}
	if _, err := s.ToolDispatch(ctx, space.ID.String(), "worker", "tool_dev", `{"input":"perform task"}`); errs.CodeOf(err) != errs.CodeConflict || calls != 1 {
		t.Fatalf("uncertain operation replayed: %v calls=%d", err, calls)
	}
}

func TestUnknownToolReturnsNotFound(t *testing.T) {
	s, ctx := messageToolHarness(t)
	if _, err := s.ToolDispatch(ctx, identity.ID{Node: 1, Entity: 99}.String(), "worker", "unknown_tool", `{}`); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("unknown tool reported success: %v", err)
	}
}

func TestFailedEventPreservesPartialToolOutput(t *testing.T) {
	s, ctx := messageToolHarness(t)
	ctx = vmm.WithExecution(ctx, vmm.Execution{RunID: "run", StepID: "0", ToolCallID: "operation"})
	event, _, err := s.beginToolEvent(ctx, vmm.NewExecutionEvent(ctx, "worker", "file_send", `{}`, "", "running"))
	if err != nil {
		t.Fatal(err)
	}
	if err := s.finishToolEvent(ctx, event, "file uploaded; message delivery unconfirmed", errs.New(errs.CodeUnavailable, "connection lost")); err != nil {
		t.Fatal(err)
	}
	var stored execution.Event
	if err := s.R.GetString(ctx, "execution_events", event.ID, &stored); err != nil || stored.Status != "failed" || !strings.Contains(stored.Result, "file uploaded") || !strings.Contains(stored.Result, "UNAVAILABLE") {
		t.Fatalf("partial evidence lost: %+v %v", stored, err)
	}
}

func TestSandboxExitStatusIsNotASuccessOrRetryGuarantee(t *testing.T) {
	for _, output := range []string{"exit=1\nsyntax defect", "exit=127\nmissing utility"} {
		err := sandboxCommandError(output)
		if errs.CodeOf(err) != vmm.CodeToolExecutionFailed {
			t.Fatal("shell failure accepted")
		}
		feedback := vmm.ToolFailureResult("sandbox_exec", output, err)
		if !strings.Contains(feedback, output[:6]) || !strings.Contains(feedback, "partial effects") {
			t.Fatal("diagnostics or uncertainty lost")
		}
	}
	for _, output := range []string{"exit=0\nvalid", "no exit header", "exit=invalid"} {
		if sandboxCommandError(output) != nil {
			t.Fatal("fabricated shell failure")
		}
	}
}

func TestToolCatalogNamesStayBoundToTheSameBackend(t *testing.T) {
	s, ctx := messageToolHarness(t)
	spaceID := identity.ID{Node: 1, Entity: 99}
	for index := uint64(1); index <= 3; index++ {
		botID := identity.ID{Node: 1, Entity: identity.EntityID(index)}
		record := bot.Bot{Entity: entity.Entity{ID: botID}, Name: "same name", Kind: bot.KindTool}
		if err := s.R.CreateID(ctx, "bots", botID, &record); err != nil {
			t.Fatal(err)
		}
		memberID := identity.ID{Node: 1, Entity: identity.EntityID(100 + index)}
		member := membership.Membership{Entity: entity.Entity{ID: memberID}, SpaceID: spaceID, MemberID: botID, Role: membership.RoleBot}
		if err := s.R.CreateID(ctx, "memberships", memberID, &member); err != nil {
			t.Fatal(err)
		}
	}
	duplicateID := identity.ID{Node: 1, Entity: 104}
	duplicate := membership.Membership{Entity: entity.Entity{ID: duplicateID}, SpaceID: spaceID, RoomID: identity.ID{Node: 1, Entity: 200}, MemberID: identity.ID{Node: 1, Entity: 1}, Role: membership.RoleBot}
	if err := s.R.CreateID(ctx, "memberships", duplicateID, &duplicate); err != nil {
		t.Fatal(err)
	}
	expected := map[string]string{}
	for attempt := 0; attempt < 20; attempt++ {
		tools, err := s.SpaceTools(ctx, spaceID, identity.ID{})
		if err != nil {
			t.Fatal(err)
		}
		actual := map[string]string{}
		for _, tool := range tools {
			if strings.HasPrefix(tool.Name, "tool_") {
				actual[tool.Name] = tool.BotID
			}
		}
		if len(actual) != 3 {
			t.Fatal("colliding names lost a tool")
		}
		if attempt == 0 {
			expected = actual
			continue
		}
		for name, backend := range expected {
			if actual[name] != backend {
				t.Fatal("database ordering changed the callable tool backend")
			}
		}
	}
}

// An app added to the whole space (no room) is in every room: an agent
// working in a room, and the App UI catalog built from there, see it next to
// the room's own apps — and never another room's.
func TestSpaceWideAppsAreSeenFromEveryRoom(t *testing.T) {
	s, ctx := messageToolHarness(t)
	spaceID := identity.ID{Node: 1, Entity: 99}
	room, other := identity.ID{Node: 1, Entity: 200}, identity.ID{Node: 1, Entity: 201}
	add := func(n uint64, name string, roomID identity.ID) {
		botID := identity.ID{Node: 1, Entity: identity.EntityID(n)}
		if err := s.R.CreateID(ctx, "bots", botID, &bot.Bot{Entity: entity.Entity{ID: botID}, Name: name, Kind: bot.KindTool}); err != nil {
			t.Fatal(err)
		}
		memberID := identity.ID{Node: 1, Entity: identity.EntityID(100 + n)}
		if err := s.R.CreateID(ctx, "memberships", memberID, &membership.Membership{Entity: entity.Entity{ID: memberID}, SpaceID: spaceID, RoomID: roomID, MemberID: botID, Role: membership.RoleBot}); err != nil {
			t.Fatal(err)
		}
	}
	add(1, "Pricing", identity.ID{})
	add(2, "Notes", room)
	add(3, "Elsewhere", other)
	names := func(roomID identity.ID) string {
		tools, err := s.SpaceTools(ctx, spaceID, roomID)
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, tool := range tools {
			out = append(out, tool.Name)
		}
		sort.Strings(out)
		return strings.Join(out, ",")
	}
	if got := names(room); !strings.Contains(got, "pricing") || !strings.Contains(got, "notes") || strings.Contains(got, "elsewhere") {
		t.Fatalf("from the room: %s", got)
	}
	if got := names(identity.ID{}); !strings.Contains(got, "pricing") || !strings.Contains(got, "notes") || !strings.Contains(got, "elsewhere") {
		t.Fatalf("the whole space: %s", got)
	}
}
