package usage

import (
	"strings"
	"testing"
)

func TestSummaryCredits(t *testing.T) {
	cases := map[int64]string{5_000: "<1 credit", 10_000: "≈1 credits", 18_000: "≈1.8 credits", 18_960: "≈1.9 credits", 123_400: "≈12.3 credits"}
	for cost, want := range cases {
		if got := (Delta{TokensIn: 1, Cost: cost}).Summary(); !strings.HasSuffix(got, want) {
			t.Errorf("cost %d: %q, want suffix %q", cost, got, want)
		}
	}
}
