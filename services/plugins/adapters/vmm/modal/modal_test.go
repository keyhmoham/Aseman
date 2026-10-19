package modal

import (
	"testing"
	"time"
)

func TestProviderLimitsFollowTheAdminAndDefaultSafely(t *testing.T) {
	var none machineSizes
	if none.lifetime() != 8*time.Hour || none.idleLimit() != 30*time.Minute || none.commandLimit() != 300*time.Second {
		t.Fatalf("defaults = %v / %v / %v", none.lifetime(), none.idleLimit(), none.commandLimit())
	}
	set := machineSizes{MaxLifetimeMin: 120, ProviderIdleMin: 10, CommandTimeoutSec: 60}
	if set.lifetime() != 2*time.Hour || set.idleLimit() != 10*time.Minute || set.commandLimit() != time.Minute {
		t.Fatalf("admin limits = %v / %v / %v", set.lifetime(), set.idleLimit(), set.commandLimit())
	}
	// The idle limit can never outlast the lifetime.
	if got := (machineSizes{MaxLifetimeMin: 20, ProviderIdleMin: 90}).idleLimit(); got != 20*time.Minute {
		t.Fatalf("idle limit %v exceeds the lifetime", got)
	}
}
