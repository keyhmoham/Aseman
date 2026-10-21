package routine

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	rt "github.com/aseman/aseman/plugins/actions/routines/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

type fakeSpaces struct {
	asks           int
	mu             sync.Mutex
	dispatchErr    error
	dispatchResult string
}

func (f *fakeSpaces) AskBot(_ context.Context, _ identity.ID, _ identity.ID, _ string, _ []vmm.FileAttachment, _ []vmm.ChatMessage) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asks++
	if f.dispatchResult != "" {
		return f.dispatchResult, f.dispatchErr
	}
	return "ok", f.dispatchErr
}
func (f *fakeSpaces) SandboxExec(_ context.Context, _ identity.ID, _ string) (string, error) {
	return "ok", nil
}

func (f *fakeSpaces) RunScheduledTask(context.Context, identity.ID, identity.ID, identity.ID, string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asks++
	return "ok", f.dispatchErr
}

func harness(t *testing.T) (*Service, *fakeSpaces, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global()})
	fake := &fakeSpaces{}
	s := NewService(k, &repo.Repo{DB: db}, logger.Global())
	s.Spaces = fake
	workspace := mustID(t, "00000000000000010000000000000099")
	roomID := mustID(t, "00000000000000010000000000000098")
	creator := mustID(t, "00000000000000010000000000000001")
	account := mustID(t, "00000000000000010000000000000002")
	room := space.Room{Entity: entity.Entity{ID: roomID}, SpaceID: workspace}
	agent := bot.Bot{Entity: entity.Entity{ID: creator}, AccountID: account}
	for _, record := range []struct {
		model string
		id    identity.ID
		value any
	}{
		{"spaces", workspace, &space.Space{Entity: entity.Entity{ID: workspace}}},
		{"rooms", roomID, &room}, {"bots", creator, &agent},
		{"memberships", mustID(t, "00000000000000010000000000000003"), &membership.Membership{Entity: entity.Entity{ID: mustID(t, "00000000000000010000000000000003")}, SpaceID: workspace, MemberID: creator, Role: membership.RoleOwner}},
		{"memberships", mustID(t, "00000000000000010000000000000004"), &membership.Membership{Entity: entity.Entity{ID: mustID(t, "00000000000000010000000000000004")}, SpaceID: workspace, MemberID: account, Role: membership.RoleBot}},
	} {
		if err := s.R.DB.Create(ctx, record.model, record.id.String(), record.value); err != nil {
			t.Fatal(err)
		}
	}
	return s, fake, ctx
}

func TestCreateListAndFireDelayed(t *testing.T) {
	s, fake, ctx := harness(t)
	space := mustID(t, "00000000000000010000000000000099")
	room := mustID(t, "00000000000000010000000000000098")
	creator := mustID(t, "00000000000000010000000000000001")

	// Delayed routine firing soon.
	r, err := s.Create(ctx, space, room, creator, "scan", rt.Delayed, "00000000000000010000000000000001", "scan the market", 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if r.Type != rt.Delayed {
		t.Fatalf("type = %s", r.Type)
	}
	list, err := s.List(ctx, space, room)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 {
		t.Fatalf("list len = %d", len(list))
	}

	// Force the next run into the past and fire it.
	r.NextRunAt = time.Now().Add(-time.Second)
	if err := s.R.Update(ctx, "routines", r.ID, r); err != nil {
		t.Fatal(err)
	}
	if err := s.RunDue(ctx); err != nil {
		t.Fatal(err)
	}
	// The delayed routine dispatched to the target agent once and is done.
	if fake.asks != 1 {
		t.Fatalf("expected 1 dispatch, got %d", fake.asks)
	}
	got, _ := s.Get(ctx, r.ID)
	if got.Status != rt.Done {
		t.Fatalf("status = %s, want done", got.Status)
	}
}

func TestPeriodicReschedules(t *testing.T) {
	s, _, ctx := harness(t)
	space := mustID(t, "00000000000000010000000000000099")
	room := mustID(t, "00000000000000010000000000000098")
	creator := mustID(t, "00000000000000010000000000000001")
	r, err := s.Create(ctx, space, room, creator, "every", rt.Periodic, "", "ping", 0, 10)
	if err != nil {
		t.Fatal(err)
	}
	r.NextRunAt = time.Now().Add(-time.Second)
	_ = s.R.Update(ctx, "routines", r.ID, r)
	if err := s.RunDue(ctx); err != nil {
		t.Fatal(err)
	}
	got, _ := s.Get(ctx, r.ID)
	if got.Status != rt.Active {
		t.Fatalf("periodic status = %s, want active", got.Status)
	}
	if !got.NextRunAt.After(time.Now().Add(5 * time.Second)) {
		t.Fatalf("periodic should reschedule ~10s ahead, next=%v", got.NextRunAt)
	}
	if got.LastResult == "" {
		t.Fatal("expected last result recorded")
	}
}

func TestDefaultScheduleIsPersistedAndSurvivesMetadataUpdate(t *testing.T) {
	for _, tc := range []struct {
		typ     rt.Type
		seconds int64
	}{{rt.Delayed, 60}, {rt.Periodic, 3600}} {
		s, _, ctx := harness(t)
		s.now = func() time.Time { return time.Date(2026, 10, 6, 0, 0, 0, 0, time.UTC) }
		sp := mustID(t, "00000000000000010000000000000099")
		room := mustID(t, "00000000000000010000000000000098")
		owner := mustID(t, "00000000000000010000000000000001")
		r, err := s.Create(ctx, sp, room, owner, "defaults", tc.typ, "", "refresh", 0, 0)
		if err != nil {
			t.Fatal(err)
		}
		if r.NextRunAt != s.now().Add(time.Duration(tc.seconds)*time.Second) || (tc.typ == rt.Periodic && r.IntervalSec != tc.seconds) || (tc.typ == rt.Delayed && r.DelaySec != tc.seconds) {
			t.Fatalf("default schedule not persisted: %+v", r)
		}
		// Simulate an older persisted row that did not retain the effective default.
		r.DelaySec, r.IntervalSec = 0, 0
		if err := s.R.Update(ctx, "routines", r.ID, r); err != nil {
			t.Fatal(err)
		}
		updated, err := s.Update(ctx, r.ID, "renamed", "", "", 0, 0)
		if err != nil {
			t.Fatal(err)
		}
		if updated.NextRunAt != s.now().Add(time.Duration(tc.seconds)*time.Second) {
			t.Fatal("metadata update made a default routine immediately due")
		}
	}
}

func TestPauseResumeDelete(t *testing.T) {
	s, _, ctx := harness(t)
	space := mustID(t, "00000000000000010000000000000099")
	room := mustID(t, "00000000000000010000000000000098")
	creator := mustID(t, "00000000000000010000000000000001")
	r, err := s.Create(ctx, space, room, creator, "x", rt.Delayed, "", "do", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Pause(ctx, r.ID); err != nil {
		t.Fatal(err)
	}
	p, _ := s.Get(ctx, r.ID)
	if p.Status != rt.Paused {
		t.Fatalf("pause status = %s", p.Status)
	}
	if _, err := s.Resume(ctx, r.ID); err != nil {
		t.Fatal(err)
	}
	rr, _ := s.Get(ctx, r.ID)
	if rr.Status != rt.Active {
		t.Fatalf("resume status = %s", rr.Status)
	}
	if err := s.Delete(ctx, r.ID); err != nil {
		t.Fatal(err)
	}
	list, _ := s.List(ctx, space, room)
	if len(list) != 0 {
		t.Fatalf("expected empty list after delete, got %d", len(list))
	}
}

func mustID(t *testing.T, h string) identity.ID {
	t.Helper()
	id, err := identity.Parse(h)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func TestListWithoutARoomShowsEveryRoomOfTheProject(t *testing.T) {
	s, _, ctx := harness(t)
	space := mustID(t, "00000000000000010000000000000099")
	room := mustID(t, "00000000000000010000000000000098")
	creator := mustID(t, "00000000000000010000000000000001")
	if _, err := s.Create(ctx, space, room, creator, "in a thread", rt.Periodic, "", "ping", 0, 600); err != nil {
		t.Fatal(err)
	}
	// The project's routine card asks for the project, not for one thread.
	all, err := s.List(ctx, space, identity.ID{})
	if err != nil || len(all) != 1 {
		t.Fatalf("project-wide list = %d routines, %v; want the routine made in a thread", len(all), err)
	}
}

func TestDailyRoutineKeepsItsWallClockHourAcrossDaylightSaving(t *testing.T) {
	london, err := time.LoadLocation("Europe/London")
	if err != nil {
		t.Skip("no tz database")
	}
	// Clocks go back on 25 Oct 2026 (BST, UTC+1, becomes GMT, UTC+0). The run on
	// the 24th is 09:00 BST; asked after it, the next is 09:00 GMT the next day —
	// 25 hours later, because the hour on the wall clock is what is kept.
	ranOn24th := time.Date(2026, 10, 24, 9, 0, 0, 0, london)
	next, err := rt.NextDaily("09:00", "Europe/London", ranOn24th)
	if err != nil || !next.Equal(time.Date(2026, 10, 25, 9, 0, 0, 0, london)) || next.Sub(ranOn24th) != 25*time.Hour {
		t.Fatalf("next = %v (%v after), %v; want 25 Oct 09:00 London, 25h later", next, next.Sub(ranOn24th), err)
	}
	// And the day after that is a plain 24 hours.
	if after, _ := rt.NextDaily("09:00", "Europe/London", next); after.Sub(next) != 24*time.Hour {
		t.Fatalf("the following day is %v later; want 24h", after.Sub(next))
	}
	after := ranOn24th.Add(3 * time.Hour)
	// Before 09:00 the same day runs the same day.
	morning := time.Date(2026, 10, 24, 7, 0, 0, 0, london)
	if got, _ := rt.NextDaily("09:00", "Europe/London", morning); !got.Equal(time.Date(2026, 10, 24, 9, 0, 0, 0, london)) {
		t.Fatalf("7am asked, got %v", got)
	}
	for _, bad := range [][2]string{{"9am", "Europe/London"}, {"25:00", "UTC"}, {"09:00", "Mars/Base"}} {
		if _, err := rt.NextDaily(bad[0], bad[1], after); err == nil {
			t.Fatalf("accepted at=%q timezone=%q", bad[0], bad[1])
		}
	}
}

func TestSetDailyTurnsARoutineIntoAnEverydayOne(t *testing.T) {
	s, _, ctx := harness(t)
	space := mustID(t, "00000000000000010000000000000099")
	room := mustID(t, "00000000000000010000000000000098")
	creator := mustID(t, "00000000000000010000000000000001")
	// What the agent did before: a one-shot with the delay worked out by hand.
	r, err := s.Create(ctx, space, room, creator, "joke", rt.Delayed, "", "tell a joke", 36080, 0)
	if err != nil {
		t.Fatal(err)
	}
	daily, err := s.SetDaily(ctx, r.ID, "09:00", "Europe/London")
	if err != nil {
		t.Fatal(err)
	}
	if daily.Type != rt.Periodic || daily.At != "09:00" || daily.Timezone != "Europe/London" || daily.IntervalSec != 86400 {
		t.Fatalf("daily = %+v", daily)
	}
	// It runs, and runs again tomorrow at 09:00 London — not a day after it finished.
	daily.NextRunAt = time.Now().Add(-time.Second)
	_ = s.R.Update(ctx, "routines", daily.ID, daily)
	if err := s.RunDue(ctx); err != nil {
		t.Fatal(err)
	}
	got, _ := s.Get(ctx, daily.ID)
	london, _ := time.LoadLocation("Europe/London")
	if got.Status != rt.Active || got.NextRunAt.In(london).Format("15:04") != "09:00" || !got.NextRunAt.After(time.Now()) {
		t.Fatalf("after a run: %s, next %v; want active and the next 09:00 London", got.Status, got.NextRunAt.In(london))
	}
}

func TestAnIntervalRoutineKeepsItsCadenceInsteadOfDriftingByTheRunTime(t *testing.T) {
	due := time.Date(2026, 10, 9, 9, 0, 0, 0, time.UTC)
	r := &rt.Routine{IntervalSec: 86400, NextRunAt: due}
	// The run finished 40 seconds late; the next one is still due at the same time tomorrow.
	if got := nextPeriodicRun(r, due.Add(40*time.Second)); !got.Equal(due.Add(24 * time.Hour)) {
		t.Fatalf("next = %v; want exactly a day after it was due", got)
	}
	// A node that was down for three days does not replay them, it picks the next slot.
	if got := nextPeriodicRun(r, due.Add(3*24*time.Hour+time.Hour)); !got.Equal(due.Add(4 * 24 * time.Hour)) {
		t.Fatalf("after downtime next = %v; want the next slot on the same cadence", got)
	}
}

func TestRoutineOfDeletedProjectIsRemoved(t *testing.T) {
	s, fake, ctx := harness(t)
	ws := mustID(t, "00000000000000010000000000000099")
	room := mustID(t, "00000000000000010000000000000098")
	creator := mustID(t, "00000000000000010000000000000001")
	r, err := s.Create(ctx, ws, room, creator, "daily", rt.Periodic, "00000000000000010000000000000001", "report", 0, 60)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.R.Delete(ctx, "spaces", ws); err != nil {
		t.Fatal(err)
	}
	r.NextRunAt = time.Now().Add(-time.Minute)
	if err := s.R.Update(ctx, "routines", r.ID, r); err != nil {
		t.Fatal(err)
	}
	if err := s.RunDue(ctx); err != nil {
		t.Fatal(err)
	}
	var got rt.Routine
	if err := s.R.Get(ctx, "routines", r.ID, &got); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("routine of a deleted project still exists: %v", err)
	}
	if fake.asks != 0 {
		t.Fatal("routine of a deleted project fired")
	}
}
