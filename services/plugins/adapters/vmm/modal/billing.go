package modal

import (
	"context"
	"io"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"

	pb "github.com/modal-labs/modal-client/go/proto/modal_proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// sandboxApp is the Modal app every project computer runs under.
const sandboxApp = "tradera-sandboxes"

var _ vmm.CostReporter = (*Adapter)(nil)

// CostReport (vmm.CostReporter) is what Modal billed for the project computers
// (the "tradera-sandboxes" app) from [since] to [until], by day (UTC) and by
// resource (CPU, memory, network). It is Modal's own workspace billing report,
// so it is the real bill, not an estimate. Modal may take a little while to
// include the latest minutes.
func (a *Adapter) CostReport(ctx context.Context, since, until time.Time) ([]vmm.ProviderCost, error) {
	api, err := a.api(ctx)
	if err != nil {
		return nil, err
	}
	if until.IsZero() {
		until = time.Now()
	}
	if since.IsZero() || since.After(until) {
		since = until.AddDate(0, 0, -30)
	}
	start := since.UTC().Truncate(24 * time.Hour)
	end := until.UTC().Truncate(24 * time.Hour).Add(24 * time.Hour)
	stream, err := api.WorkspaceBillingReport(ctx, pb.WorkspaceBillingReportRequest_builder{
		StartTimestamp: timestamppb.New(start), EndTimestamp: timestamppb.New(end), Resolution: "d",
	}.Build())
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "modal billing report")
	}
	days := map[time.Time]*vmm.ProviderCost{}
	for {
		item, err := stream.Recv()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, errs.Wrap(errs.CodeVMM, err, "modal billing report")
		}
		if item.GetDescription() != sandboxApp {
			continue
		}
		// Another environment's app of the same name is not this node's bill.
		if a.environment != "" && item.GetEnvironmentName() != a.environment {
			continue
		}
		day := item.GetInterval().AsTime().UTC().Truncate(24 * time.Hour)
		cost, _ := strconv.ParseFloat(strings.TrimSpace(item.GetCost()), 64)
		row := days[day]
		if row == nil {
			row = &vmm.ProviderCost{Day: day, ByResource: map[string]float64{}}
			days[day] = row
		}
		row.USD += cost
		for resource, value := range item.GetCostByResource() {
			v, _ := strconv.ParseFloat(strings.TrimSpace(value), 64)
			row.ByResource[resource] += v
		}
	}
	out := make([]vmm.ProviderCost, 0, len(days))
	for _, row := range days {
		out = append(out, *row)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Day.Before(out[j].Day) })
	return out, nil
}
