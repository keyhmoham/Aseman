package admin

import (
	"context"
	"errors"
	"testing"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/auth/schema"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/memory"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
	"golang.org/x/crypto/bcrypt"
)

func TestAdminPasswordUsesPersistedCredentials(t *testing.T) {
	ctx := context.Background()
	hash := func(p string) string {
		b, err := bcrypt.GenerateFromPassword([]byte(p), bcrypt.MinCost)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	changed, defaultHash := hash("changed-password"), hash("changeme")
	for _, tc := range []struct {
		name, env, status string
		rows              []account.Account
	}{
		{"changed through profile", "changeme", "ok", []account.Account{{Kind: account.KindUser, Status: account.StatusActive, Handle: "node-a", PasswordHash: changed}}},
		{"env changed but database default", "new-bootstrap-password", "fail", []account.Account{{Kind: account.KindUser, Status: account.StatusActive, Role: "admin", PasswordHash: defaultHash}}},
		{"renamed admin", "", "fail", []account.Account{{Kind: account.KindUser, Status: account.StatusActive, Role: "admin", Handle: "renamed", PasswordHash: defaultHash}}},
		{"second admin default", "", "fail", []account.Account{{Kind: account.KindUser, Status: account.StatusActive, Role: "admin", PasswordHash: changed}, {Kind: account.KindUser, Status: account.StatusActive, Role: "admin", PasswordHash: defaultHash}}},
		{"disabled default account", "", "ok", []account.Account{{Kind: account.KindUser, Status: account.StatusActive, Role: "admin", PasswordHash: changed}, {Kind: account.KindUser, Status: account.StatusDisabled, Role: "admin", PasswordHash: defaultHash}}},
		{"no admins", "", "warn", nil},
		{"malformed hash", "", "fail", []account.Account{{Kind: account.KindUser, Status: account.StatusActive, Role: "admin", PasswordHash: "malformed"}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("TRADERA_ADMIN_PASSWORD", tc.env)
			db := memory.New(logger.Global())
			for _, m := range schema.Models() {
				if err := db.RegisterModel(ctx, m); err != nil {
					t.Fatal(err)
				}
			}
			r := &repo.Repo{DB: db}
			for _, a := range tc.rows {
				id, _ := identity.New(1)
				a.ID = id
				if err := r.CreateID(ctx, "accounts", id, &a); err != nil {
					t.Fatal(err)
				}
			}
			if c := adminPasswordHealth(ctx, r, "node-a"); c.Status != tc.status {
				t.Fatalf("got %+v, want %s", c, tc.status)
			}
		})
	}
	if c := adminPasswordHealth(ctx, &repo.Repo{DB: unreadableDB{}}, "node-a"); c.Status != "fail" {
		t.Fatal("database failure returned healthy")
	}
}

type unreadableDB struct{ database.Database }

func (unreadableDB) List(context.Context, string, database.Filter, any) error {
	return errors.New("database unavailable")
}
