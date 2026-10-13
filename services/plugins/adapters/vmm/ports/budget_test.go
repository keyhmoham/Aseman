package vmm

import (
	"context"
	"sync"
	"testing"
)

func TestUsageAccountingNeverRejectsOrDelaysConcurrentCalls(t *testing.T) {
	parent := &Budget{Limit: 1, Used: 1000000}
	child := parent.Scope(1)
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			reservation, err := child.ReserveOutput(context.Background(), 100000, 16384)
			if err != nil || reservation.MaxOutput != 16384 {
				t.Errorf("request rejected: %v", err)
				return
			}
			if !reservation.Finish(10000, 1000) {
				t.Error("provider result discarded")
			}
			reservation.Finish(10000, 1000) // Repeated settlement cannot double count.
		}()
	}
	wg.Wait()
	for _, counter := range []*Budget{parent, child} {
		in, out := counter.Totals()
		if in != 200000 || out != 20000 {
			t.Fatalf("usage %d/%d", in, out)
		}
	}
	if parent.Used != 1220000 || child.Used != 220000 {
		t.Fatal("incorrect accumulated usage")
	}
}

func TestUnlimitedScopesAndLegacyAccountingKeepAllUsage(t *testing.T) {
	parent := &Budget{}
	child := parent.Scope(100)
	reservation, err := child.Reserve(context.Background(), 100000)
	if err != nil {
		t.Fatal(err)
	}
	reservation.Finish(10000, 2000)
	child.Charge(10)
	child.RecordTokens(5, 5)
	in, out := parent.Totals()
	if parent.Used != 12010 || in != 10005 || out != 2005 {
		t.Fatalf("usage=%d/%d/%d", parent.Used, in, out)
	}
}

func TestUsageReservationHonorsExplicitCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := (&Budget{}).Reserve(ctx, 10); err != context.Canceled {
		t.Fatalf("cancellation ignored: %v", err)
	}
}

func TestCapabilitiesCannotBeWidenedByAgent(t *testing.T) {
	allowed := IntersectCapabilities([]string{"file_read"}, []string{"file_read", "sandbox_exec"})
	policy := Execution{Capabilities: allowed}
	if !policy.Allows("file_read") || policy.Allows("sandbox_exec") {
		t.Fatalf("capability intersection = %v", allowed)
	}
	if (Execution{Capabilities: IntersectCapabilities([]string{}, nil)}).Allows("file_read") {
		t.Fatal("empty host grant became unrestricted")
	}
}
