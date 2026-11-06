package spaces

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
)

// Many people opening a sleeping platform at once wake its computer once,
// as the publisher; a client polling meanwhile is told to wait.
func TestAFrontendsComputerIsWokenOnceForEveryone(t *testing.T) {
	s, ctx := appAccessHarness(t)
	publisher := directPerson(t, s, ctx, "00000000000000010000000000000001", "founder")
	sp, err := s.CreateSpace(ctx, publisher, "studio", "")
	if err != nil {
		t.Fatal(err)
	}
	p := appPreview(t, s, ctx, sp.ID, "Store")
	release := make(chan struct{})
	var opens atomic.Int32
	var as identity.ID
	s.wakeOpenFn = func(_ context.Context, id, actor identity.ID) (map[string]any, error) {
		opens.Add(1)
		as = actor
		<-release
		return map[string]any{"ready": true}, nil
	}
	first, err := s.WakeFrontend(ctx, p.ID, publisher, 0)
	if err != nil || first.State != proxy.WakeWaking || first.RetryAfterMs == 0 {
		t.Fatalf("first: %+v %v", first, err)
	}
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if w, err := s.WakeFrontend(ctx, p.ID, publisher, 5*time.Second); err != nil || !w.Ready {
				t.Errorf("joined wake: %+v %v", w, err)
			}
		}()
	}
	time.Sleep(50 * time.Millisecond)
	close(release)
	wg.Wait()
	if opens.Load() != 1 || as != publisher {
		t.Fatalf("opened %d times as %v", opens.Load(), as)
	}
}

// A failed wake is reported for a while instead of being retried by
// everyone who arrives.
func TestAFailedWakeIsNotRetriedAtOnce(t *testing.T) {
	s, ctx := appAccessHarness(t)
	publisher := directPerson(t, s, ctx, "00000000000000010000000000000001", "founder")
	sp, err := s.CreateSpace(ctx, publisher, "studio", "")
	if err != nil {
		t.Fatal(err)
	}
	p := appPreview(t, s, ctx, sp.ID, "Store")
	var opens atomic.Int32
	s.wakeOpenFn = func(context.Context, identity.ID, identity.ID) (map[string]any, error) {
		opens.Add(1)
		return nil, errors.New("not enough funds to start the computer")
	}
	w, err := s.WakeFrontend(ctx, p.ID, publisher, 2*time.Second)
	if err != nil || w.State != proxy.WakeFailed || w.Error == "" {
		t.Fatalf("wake: %+v %v", w, err)
	}
	again, _ := s.WakeFrontend(ctx, p.ID, publisher, 2*time.Second)
	if again.State != proxy.WakeFailed || again.RetryAfterMs <= 0 || opens.Load() != 1 {
		t.Fatalf("again: %+v (opened %d)", again, opens.Load())
	}
	if _, err := s.WakeFrontend(ctx, p.ID, identity.ID{}, 0); err == nil {
		t.Fatal("a wake with no publisher")
	}
}
