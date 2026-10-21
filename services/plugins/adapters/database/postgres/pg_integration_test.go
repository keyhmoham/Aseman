package postgres

import (
	"context"
	"os"
	"testing"

	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

// TestListAccountsRequiresDSN guards the integration test below.
func TestPostgresIntegration(t *testing.T) {
	dsn := os.Getenv("ASEMAN_TEST_PG")
	if dsn == "" {
		t.Skip("set ASEMAN_TEST_PG to run postgres integration tests")
	}
	ad := New(logger.Global())
	if err := ad.Open(context.Background(), database.Config{DSN: dsn}); err != nil {
		t.Fatalf("open: %v", err)
	}
	defer ad.Close(context.Background())
	ctx := context.Background()
	for _, m := range dbmodel.Models() {
		if err := ad.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	var list []account.Account
	if err := ad.List(ctx, "accounts", database.Filter{Equal: map[string]any{"handle": "node-a"}}, &list); err != nil {
		t.Fatalf("list accounts by handle: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("expected 1 account, got %d", len(list))
	}
	if list[0].Handle != "node-a" || list[0].Status != account.StatusActive {
		t.Fatalf("unexpected account: %+v", list[0])
	}
}
