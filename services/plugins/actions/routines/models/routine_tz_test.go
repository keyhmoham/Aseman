package routine

import (
	"testing"
	"time"
)

// A daily routine is scheduled in the person's own timezone, by its IANA name.
func TestNextDailyInNamedTimezone(t *testing.T) {
	after := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	got, err := NextDaily("19:30", "Europe/London", after)
	if err != nil {
		t.Fatal(err)
	}
	// 19:30 BST on 15 October is 18:30 UTC.
	if want := time.Date(2026, 10, 15, 18, 30, 0, 0, time.UTC); !got.Equal(want) {
		t.Fatalf("next = %s, want %s", got, want)
	}
}
