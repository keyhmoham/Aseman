package tenancy

import "testing"

func TestSees(t *testing.T) {
	bridged := map[string]bool{"acme": true}
	cases := []struct {
		viewer, entity string
		want           bool
	}{
		{Main, Main, true},
		{"acme", "acme", true},
		{"acme", "other", false},
		{"other", "acme", false},
		{Main, "acme", true},
		{"acme", Main, true},
		{Main, "other", false},
		{"other", Main, false},
	}
	for _, tc := range cases {
		if got := Sees(tc.viewer, tc.entity, bridged); got != tc.want {
			t.Fatalf("Sees(%q,%q)=%v want %v", tc.viewer, tc.entity, got, tc.want)
		}
	}
}
