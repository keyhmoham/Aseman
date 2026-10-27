package spaces

import (
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func TestOpenCodeIsOffUntilAnAdminTurnsItOn(t *testing.T) {
	s, ctx := messageToolHarness(t)
	if on, err := s.OpenCodeEnabled(ctx); err != nil || on {
		t.Fatalf("OpenCode must be off by default: %v %v", on, err)
	}
	view, err := s.openCodeView(ctx)
	if err != nil || view["enabled"] != false || view["builder"] != "agents" {
		t.Fatalf("off view: %v %v", view, err)
	}
	if _, err := s.SetOpenCode(ctx, true); err != nil {
		t.Fatal(err)
	}
	if !s.openCodeOn(ctx) {
		t.Fatal("turned on, OpenCode must be on")
	}
	if view, _ := s.openCodeView(ctx); view["builder"] != "opencode" {
		t.Fatalf("on view: %v", view)
	}
	if _, err := s.SetOpenCode(ctx, false); err != nil {
		t.Fatal(err)
	}
	if s.openCodeOn(ctx) {
		t.Fatal("turned off again, OpenCode must be off")
	}
}

func TestOpenCodeLeavesTheToolsCleanlyWhenOff(t *testing.T) {
	s, ctx := messageToolHarness(t)
	ctx = helper.WithInternalAccess(ctx)
	spaceID := idFromHex(t, "00000000000000010000000000000001")
	listed := func() map[string]vmm.Tool {
		tools, err := s.SpaceTools(ctx, spaceID, spaceID)
		if err != nil {
			t.Fatal(err)
		}
		out := map[string]vmm.Tool{}
		for _, tool := range tools {
			out[tool.Name] = tool
		}
		return out
	}

	off := listed()
	for _, gone := range []string{"opencode", "opencode_run", "opencode_status", "opencode_models"} {
		if _, ok := off[gone]; ok {
			t.Fatalf("%s is offered while OpenCode is off", gone)
		}
	}
	for _, want := range []string{"appui_create", "appui_publish", "appui_status"} {
		if _, ok := off[want]; !ok {
			t.Fatalf("%s must be offered in both modes", want)
		}
	}
	create := off["appui_create"]
	if strings.Contains(create.Description+create.Usage, "OpenCode") {
		t.Fatal("off, appui_create must not mention OpenCode")
	}
	for _, want := range []string{"appui_publish", "TASK.md", "aseman-elpian", "elpian/e2e", "READY.json"} {
		if !strings.Contains(create.Usage, want) {
			t.Fatalf("off, appui_create usage must explain %s", want)
		}
	}
	if _, err := s.ToolDispatch(ctx, spaceID.String(), "worker", "opencode_run", `{"message":"write a script"}`); errs.CodeOf(err) != errs.CodeUnavailable || !strings.Contains(err.Error(), "OpenCode is turned off") {
		t.Fatalf("opencode_run while off: %v", err)
	}

	if _, err := s.SetOpenCode(ctx, true); err != nil {
		t.Fatal(err)
	}
	on := listed()
	for _, want := range []string{"opencode", "opencode_run", "opencode_status", "opencode_models", "appui_create", "appui_publish", "appui_status"} {
		if _, ok := on[want]; !ok {
			t.Fatalf("%s must be offered while OpenCode is on", want)
		}
	}
	if !strings.Contains(on["appui_create"].Usage, "OpenCode") {
		t.Fatal("on, appui_create is OpenCode's build")
	}
}

func TestAppuiPublishNeedsAProjectDir(t *testing.T) {
	s, ctx := messageToolHarness(t)
	ctx = helper.WithInternalAccess(ctx)
	spaceID := idFromHex(t, "00000000000000010000000000000001")
	for _, args := range []string{`{}`, `{"dir":"/etc"}`, `{"dir":"/workspace/../etc"}`, `[]`} {
		if _, err := s.appuiPublishTool(ctx, spaceID, spaceID, "worker", args); errs.CodeOf(err) != errs.CodeInvalidArgument {
			t.Fatalf("%s: %v", args, err)
		}
	}
}

func TestAppuiDeskPlace(t *testing.T) {
	room := idFromHex(t, "00000000000000010000000000000002")
	other := idFromHex(t, "00000000000000010000000000000003")
	for _, c := range []struct {
		room, target identity.ID
		arg, desk    string
		arrange      identity.ID
	}{
		{room, room, "", room.String(), room},
		{room, other, other.String(), other.String(), other},
		{room, identity.ID{}, "home", "home", identity.ID{}},
		{identity.ID{}, identity.ID{}, "", "home", identity.ID{}},
	} {
		desk, arrange := appuiDeskPlace(c.room, c.target, c.arg)
		if desk != c.desk || arrange != c.arrange {
			t.Fatalf("%+v: desk %s arrange %s", c, desk, arrange)
		}
	}
}
