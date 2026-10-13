package spaces

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
)

// idleBots is the part of the bot service the idle stop uses: it reports the
// computer running until it is told to stop.
type idleBots struct {
	BotPort
	mu      sync.Mutex
	running bool
	stops   int
	stopErr error
}

func (b *idleBots) GetBot(_ context.Context, id identity.ID) (*bot.Bot, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	status := bot.StatusStopped
	if b.running {
		status = bot.StatusRunning
	}
	return &bot.Bot{Entity: entity.Entity{ID: id}, Name: "sbx-1", Kind: bot.KindTool, VMType: bot.VMTypeContainer, Status: status}, nil
}
func (b *idleBots) Lifecycle(_ context.Context, id identity.ID, op string) (*bot.Bot, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if op == "stop" {
		if b.stopErr != nil {
			return nil, b.stopErr
		}
		b.running, b.stops = false, b.stops+1
	}
	return &bot.Bot{Entity: entity.Entity{ID: id}, Status: bot.StatusStopped}, nil
}

func TestDesktopPreviewDoesNotKeepClosedComputerAliveForThirtyMinutes(t *testing.T) {
	s, b, botID, key := idleHarness(t)
	spaceID, err := identity.Parse(key)
	if err != nil {
		t.Fatal(err)
	}
	s.sandboxes[key] = &sandboxState{botID: botID}
	s.holdPreview(spaceID) // Desktop's ProxyCreate uses this same lease.
	defer s.cancelTimer(spaceID)
	st := s.sandboxes[key]
	if delay := sandboxIdleDelay(st, time.Now()); delay > 2*time.Minute || delay < 119*time.Second {
		t.Fatalf("desktop creation must use a two-minute idle lease, got %s", delay)
	}
	// An open panel's keepalive keeps it awake even with no keyboard/mouse use.
	s.touch(spaceID)
	s.idleStop(key, botID)
	if b.stopped() != 0 {
		t.Fatal("stopped an open desktop with a live keepalive")
	}
	// Once heartbeats end, neither the desktop nor its preview reserves 30 min.
	s.sandboxMu.Lock()
	st.lastActive = time.Now().Add(-2*time.Minute - time.Second)
	st.previewUntil = st.lastActive.Add(sandboxPreviewTTL)
	s.sandboxMu.Unlock()
	s.idleStop(key, botID)
	if b.stopped() != 1 {
		t.Fatal("closed desktop did not stop after two idle minutes")
	}
}

func TestIdleStopRetriesProviderFailureWithoutStoppingMeter(t *testing.T) {
	s, b, botID, key := idleHarness(t)
	b.stopErr = errors.New("provider unavailable")
	woke := time.Now().Add(-10 * time.Minute)
	st := &sandboxState{botID: botID, lastActive: woke, billedUntil: woke}
	s.sandboxes[key] = st
	s.idleStop(key, botID)
	if st.timer == nil || st.billedUntil != woke || b.stopped() != 0 {
		t.Fatal("failed stop must retain the meter and schedule a retry")
	}
	st.timer.Stop()
	b.stopErr = nil
	s.idleStop(key, botID)
	if b.stopped() != 1 || !st.billedUntil.IsZero() {
		t.Fatal("successful retry did not stop the computer and meter")
	}
}
func (b *idleBots) stopped() int { b.mu.Lock(); defer b.mu.Unlock(); return b.stops }

func idleHarness(t *testing.T) (*Service, *idleBots, identity.ID, string) {
	t.Helper()
	s, _ := profileHarness(t)
	b := &idleBots{running: true}
	s.Bots = b
	space := mustID(t, "00000000000000010000000000000099")
	botID := mustID(t, "00000000000000010000000000000077")
	return s, b, botID, space.String()
}

// The idle timer can fire a moment before the idle window is complete. It used to
// give up then, leaving the computer on for good.
func TestIdleStopLooksAgainWhenTheTimerFiresEarly(t *testing.T) {
	s, b, botID, key := idleHarness(t)
	s.sandboxes[key] = &sandboxState{botID: botID, lastActive: time.Now().Add(-sandboxIdleTTL + 30*time.Millisecond)}
	s.idleStop(key, botID)
	if b.stopped() != 0 {
		t.Fatal("stopped a computer before it had been idle long enough")
	}
	st := s.sandboxes[key]
	if st.timer == nil {
		t.Fatal("an early timer was dropped instead of looking again")
	}
	st.timer.Stop()
	// Later, when it really is idle, the same call stops it.
	s.sandboxMu.Lock()
	st.lastActive = time.Now().Add(-sandboxIdleTTL - time.Second)
	s.sandboxMu.Unlock()
	s.idleStop(key, botID)
	if b.stopped() != 1 {
		t.Fatalf("an idle computer was not stopped (stops = %d)", b.stopped())
	}
}

func TestIdleStopDoesNotStopAComputerAtWork(t *testing.T) {
	s, b, botID, key := idleHarness(t)
	s.sandboxes[key] = &sandboxState{botID: botID, active: 1, lastActive: time.Now().Add(-time.Hour)}
	s.idleStop(key, botID)
	if b.stopped() != 0 {
		t.Fatal("stopped a computer that is at work")
	}
}

// A stale timer must not hide a computer from the reaper.
func TestReaperStopsAComputerAtIdleDeadlineDespiteStaleTimer(t *testing.T) {
	s, b, botID, key := idleHarness(t)
	rec := &bot.Bot{Entity: entity.Entity{ID: botID}, Name: "sbx-1", Kind: bot.KindTool, VMType: bot.VMTypeContainer, Status: bot.StatusRunning}
	if err := s.R.CreateID(context.Background(), "bots", botID, rec); err != nil {
		t.Fatal(err)
	}
	stale := time.AfterFunc(time.Hour, func() {}) // a timer that never fires
	defer stale.Stop()
	s.sandboxes[key] = &sandboxState{botID: botID, timer: stale, lastActive: time.Now().Add(-sandboxIdleTTL - time.Second)}
	s.reapIdleSandboxes(context.Background())
	if b.stopped() != 1 {
		t.Fatalf("the reaper left a long-idle computer on (stops = %d)", b.stopped())
	}
}

func TestReaperLeavesARecentlyActiveComputerAlone(t *testing.T) {
	s, b, botID, key := idleHarness(t)
	rec := &bot.Bot{Entity: entity.Entity{ID: botID}, Name: "sbx-1", Kind: bot.KindTool, VMType: bot.VMTypeContainer, Status: bot.StatusRunning}
	if err := s.R.CreateID(context.Background(), "bots", botID, rec); err != nil {
		t.Fatal(err)
	}
	live := time.AfterFunc(time.Hour, func() {})
	defer live.Stop()
	s.sandboxes[key] = &sandboxState{botID: botID, timer: live, lastActive: time.Now().Add(-30 * time.Second)}
	s.reapIdleSandboxes(context.Background())
	if b.stopped() != 0 {
		t.Fatal("the reaper stopped a computer that was used 30 seconds ago")
	}
}
