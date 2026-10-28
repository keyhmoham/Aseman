package routine

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	rt "github.com/aseman/aseman/plugins/actions/routines/models"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

type demoComputer struct {
	commands []string
	trace    string
}

func (d *demoComputer) AskBot(context.Context, identity.ID, identity.ID, string, []vmm.FileAttachment, []vmm.ChatMessage) (string, error) {
	return "ok", nil
}
func (d *demoComputer) SandboxExec(_ context.Context, _ identity.ID, command string) (string, error) {
	d.commands = append(d.commands, command)
	if strings.Contains(command, "python3") {
		return "noise\n" + d.trace, nil
	}
	return "ok", nil
}

type draftModel struct{ seen string }

func (m *draftModel) Complete(_ context.Context, c Completion) (CompletionResult, error) {
	m.seen = c.User
	return CompletionResult{Text: `{"title":"Export weekly sales","instructions":"1. Open the shop admin.\n2. Download the CSV for {{week}}.","inputs":["week"],"schedule":"weekly mon 08:30"}`}, nil
}

func TestDemonstrationBecomesSkillAndRoutine(t *testing.T) {
	s, _, ctx := harness(t)
	computer := &demoComputer{trace: `{"commands":["2026-10-28T10:00:00Z\tcurl -u sam:hunter2 https://shop.example/export?token=ghp_` + strings.Repeat("a", 36) + `"],"pages":[{"url":"https://shop.example/admin","title":"Admin"}],"files":["/workspace/sales.csv"]}`}
	model := &draftModel{}
	s.Spaces, s.LLM = computer, model
	space := mustID(t, "00000000000000010000000000000099")
	room := mustID(t, "00000000000000010000000000000098")
	owner := mustID(t, "00000000000000010000000000000001")
	d, err := s.StartDemo(ctx, owner, space, room)
	if err != nil || d.Status != rt.DemoRecording || !strings.Contains(computer.commands[0], "PROMPT_COMMAND") {
		t.Fatalf("%+v %v", d, err)
	}
	if _, err := s.StartDemo(ctx, owner, space, room); err == nil {
		t.Fatal("one recording at a time")
	}
	d, err = s.StopDemo(ctx, owner, d.ID)
	if err != nil || d.Status != rt.DemoDrafted || d.Title != "Export weekly sales" {
		t.Fatalf("%+v %v", d, err)
	}
	if strings.Contains(model.seen, "ghp_") {
		t.Fatal("credentials are taken out before the model sees the recording")
	}
	d, err = s.SaveDemo(ctx, owner, d.ID, "", "", "08:30", "UTC")
	if err != nil || d.Status != rt.DemoSaved || d.RoutineID == "" || d.SkillPath != "/workspace/skills/export-weekly-sales/SKILL.md" {
		t.Fatalf("%+v %v", d, err)
	}
	last := computer.commands[len(computer.commands)-1]
	if !strings.Contains(last, "name: export-weekly-sales") || !strings.Contains(last, "- week") {
		t.Fatalf("the skill file: %s", last)
	}
	rid, _ := identity.Parse(d.RoutineID)
	r, err := s.Get(ctx, rid)
	if err != nil || r.At != "08:30" || !strings.Contains(r.Task, d.SkillPath) {
		t.Fatalf("the routine follows the skill: %+v %v", r, err)
	}
}

func TestRecordingsStopThemselves(t *testing.T) {
	s, _, ctx := harness(t)
	computer := &demoComputer{trace: `{"commands":[],"pages":[],"files":[]}`}
	s.Spaces, s.LLM = computer, &draftModel{}
	d, err := s.StartDemo(ctx, mustID(t, "00000000000000010000000000000001"), mustID(t, "00000000000000010000000000000099"), mustID(t, "00000000000000010000000000000098"))
	if err != nil {
		t.Fatal(err)
	}
	s.now = func() time.Time { return time.Now().Add(rt.DemoMaxDuration + time.Minute) }
	s.expireDemos(ctx)
	got, _ := s.demo(ctx, mustID(t, "00000000000000010000000000000001"), d.ID)
	if got.Status != rt.DemoFailed || !strings.Contains(got.Error, "nothing was recorded") {
		t.Fatalf("an empty recording past its limit stops and says why: %+v", got)
	}
}
