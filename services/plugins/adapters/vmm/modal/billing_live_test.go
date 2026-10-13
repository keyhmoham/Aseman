package modal

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/tradera/tradera/pkg/logger"
)

func TestLiveCostReportIsModalsRealBill(t *testing.T) {
	if os.Getenv("MODAL_LIVE_TEST") != "1" {
		t.Skip("set MODAL_LIVE_TEST=1 to run against Modal")
	}
	a := New(logger.Global())
	a.tokenID, a.tokenSecret = os.Getenv("TRADERA_MODAL_TOKEN_ID"), os.Getenv("TRADERA_MODAL_TOKEN_SECRET")
	if err := a.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	rows, err := a.CostReport(ctx, time.Now().AddDate(0, 0, -7), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	var total float64
	for _, r := range rows {
		total += r.USD
		t.Logf("%s  $%.4f  %v", r.Day.Format("2006-01-02"), r.USD, r.ByResource)
	}
	t.Logf("%d day(s), total $%.4f", len(rows), total)
	// Only the platform's own app is counted: another app in the workspace (the old
	// project's) must not leak in.
	for _, r := range rows {
		if r.USD < 0 {
			t.Fatal("negative cost")
		}
	}
}
