package finance

import (
	"context"
	"math"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// providerCostTTL is how long a provider's bill is reused: the report can take
// seconds to fetch and only moves by the minute.
const providerCostTTL = 5 * time.Minute

type providerCostEntry struct {
	at   time.Time
	rows []vmm.ProviderCost
}

var providerCostCache = struct {
	sync.Mutex
	byKey map[string]providerCostEntry
}{byKey: map[string]providerCostEntry{}}

// unitsOf turns dollars into ledger units (1,000,000 per USD).
func unitsOf(usd float64) int64 { return int64(math.Round(usd * 1_000_000)) }

// providerCosts is what the machine provider (Modal) actually billed the platform
// for project computers over a period. It sits beside what customers were charged
// for computers (overview.charged.compute), so the admin sees the real margin.
// All amounts are ledger units.
func (s *Service) providerCosts(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var in struct {
		Since time.Time `json:"since"`
		Until time.Time `json:"until"`
	}
	_ = helper.Decode(req, &in)
	if in.Until.IsZero() {
		in.Until = time.Now().UTC()
	}
	if in.Since.IsZero() {
		in.Since = in.Until.AddDate(0, 0, -30)
	}
	out := map[string]any{"provider": "modal", "available": false, "generated_at": time.Now().UTC()}
	reporter, ok := s.K.VMMFor(vmm.TypeModal).(vmm.CostReporter)
	if !ok || s.K.VMMFor(vmm.TypeModal) == nil {
		out["reason"] = "Computers are not running on Modal, so there is no provider bill to show."
		return helper.JSON(out)
	}
	key := in.Since.UTC().Format("2006-01-02") + "|" + in.Until.UTC().Format("2006-01-02")
	providerCostCache.Lock()
	hit, cached := providerCostCache.byKey[key]
	providerCostCache.Unlock()
	rows := hit.rows
	if !cached || time.Since(hit.at) > providerCostTTL {
		var err error
		if rows, err = reporter.CostReport(ctx, in.Since, in.Until); err != nil {
			out["reason"] = "Modal's billing report could not be read: " + err.Error()
			return helper.JSON(out)
		}
		providerCostCache.Lock()
		providerCostCache.byKey[key] = providerCostEntry{at: time.Now(), rows: rows}
		providerCostCache.Unlock()
	}
	var total float64
	byResource := map[string]int64{}
	days := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		total += r.USD
		for name, usd := range r.ByResource {
			byResource[name] += unitsOf(usd)
		}
		days = append(days, map[string]any{"day": r.Day.Format("2006-01-02"), "cost": unitsOf(r.USD)})
	}
	out["available"] = true
	out["cost"] = unitsOf(total)
	out["by_resource"] = byResource
	out["days"] = days
	return helper.JSON(out)
}
