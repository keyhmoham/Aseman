package auth

import (
	"context"
	"os"
	"testing"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/auth/models/session"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/database/postgres"
	dbmodel "github.com/tradera/tradera/plugins/testutil"
)

func TestLoginIntegration(t *testing.T) {
	dsn := os.Getenv("TRADERA_TEST_PG")
	if dsn == "" {
		t.Skip("set TRADERA_TEST_PG to run postgres integration tests")
	}
	ad := postgres.New(logger.Global())
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
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global()})
	r := &repo.Repo{DB: ad}
	s := &Service{K: k, R: r, L: logger.Global()}

	acc, token, priv, err := s.Login(ctx, "node-a", "changeme")
	if err != nil {
		t.Fatalf("login: %v", err)
	}
	if acc == nil || acc.Handle != "node-a" {
		t.Fatalf("unexpected account: %+v", acc)
	}
	if token == "" || priv == "" {
		t.Fatal("login must return a token and identity key")
	}
	// The token must authenticate.
	if _, err := s.Authenticate(ctx, token); err != nil {
		t.Fatalf("authenticate with issued token: %v", err)
	}
	_ = session.KindSession
}
