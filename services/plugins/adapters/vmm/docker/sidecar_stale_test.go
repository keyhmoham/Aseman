package docker

import "testing"

// A sidecar that started before its computer's current start is joined to
// the network of the computer's previous run: it must be recreated.
func TestSidecarStale(t *testing.T) {
	cases := []struct {
		sidecar, vm string
		stale       bool
	}{
		{"2026-11-07T10:00:05.123456789Z", "2026-11-07T10:00:01.5Z", false},
		{"2026-11-07T09:00:00Z", "2026-11-07T10:00:01.5Z", true},
		{"", "2026-11-07T10:00:01Z", false},
		{"2026-11-07T09:00:00Z", "", false},
	}
	for _, c := range cases {
		if got := sidecarStale(c.sidecar, c.vm); got != c.stale {
			t.Errorf("sidecarStale(%q, %q) = %v, want %v", c.sidecar, c.vm, got, c.stale)
		}
	}
}
