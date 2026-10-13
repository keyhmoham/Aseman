package spaces

import (
	"testing"
	"time"
)

// What a person has read is kept with their account, so every device agrees;
// it only moves forward, and one person's reading is not another's.
func TestReadCursorIsSharedAcrossDevicesAndOnlyMovesForward(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	other := idFromHex(t, "00000000000000010000000000000002")
	sp, err := s.CreateSpace(ctx, owner, "launch", "")
	if err != nil {
		t.Fatal(err)
	}
	if !s.SeenAt(ctx, owner, sp.ID).IsZero() {
		t.Fatal("nothing has been read yet")
	}
	first := time.Now().UTC().Add(-time.Hour).Truncate(time.Millisecond)
	if _, err := s.MarkSeen(ctx, owner, sp.ID, first); err != nil {
		t.Fatal(err)
	}
	// Another device reports an older reading: the cursor stays where it is.
	if at, err := s.MarkSeen(ctx, owner, sp.ID, first.Add(-time.Minute)); err != nil || !at.Equal(first) {
		t.Fatalf("cursor moved back: %v %v", at, err)
	}
	later := first.Add(30 * time.Minute)
	if at, _ := s.MarkSeen(ctx, owner, sp.ID, later); !at.Equal(later) || !s.SeenAt(ctx, owner, sp.ID).Equal(later) {
		t.Fatalf("cursor did not move forward: %v", at)
	}
	// A clock that is ahead cannot mark the future as read.
	if at, _ := s.MarkSeen(ctx, owner, sp.ID, time.Now().Add(24*time.Hour)); at.After(time.Now().Add(2 * time.Minute)) {
		t.Fatalf("cursor went into the future: %v", at)
	}
	if !s.SeenAt(ctx, other, sp.ID).IsZero() {
		t.Fatal("one person's reading marked it read for another")
	}
}
