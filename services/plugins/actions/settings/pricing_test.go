package settings

import (
	"testing"

	"github.com/aseman/aseman/plugins/actions/settings/models"
)

func TestParsePricing(t *testing.T) {
	if p, err := parsePricing(nil); err != nil || p != models.DefaultPricing() {
		t.Fatalf("missing pricing = %+v, %v; want the defaults", p, err)
	}
	p, err := parsePricing(map[string]any{"sandbox": map[string]any{"per_minute": 4, "cpu_per_min": 2}, "agent_per_minute": 3})
	if err != nil || p.Sandbox.PerMinute != 4 || p.Sandbox.CPUPerMin != 2 || p.AgentPerMinute != 3 || p.Tool != models.DefaultPricing().Tool {
		t.Fatalf("partial pricing = %+v, %v", p, err)
	}
	for _, bad := range []any{
		map[string]any{"sandbox": map[string]any{"per_minute": -1}},
		map[string]any{"gpu": 1},
		map[string]any{"agent_per_minute": -2},
	} {
		if _, err := parsePricing(bad); err == nil {
			t.Fatalf("accepted invalid pricing %v", bad)
		}
	}
}
