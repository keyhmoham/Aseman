package admin

import (
	"context"
	"errors"

	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
	"golang.org/x/crypto/bcrypt"
)

// Bootstrap environment values do not change an existing account's password.
// Check the persisted credentials of every account that can administer this node.
func adminPasswordHealth(ctx context.Context, r *repo.Repo, handle string) healthCheck {
	c := healthCheck{ID: "admin_password", Group: "Core", Label: "Admin password"}
	var rows []account.Account
	if err := r.List(ctx, "accounts", database.Filter{}, &rows); err != nil {
		c.Status, c.Detail = "fail", "Cannot verify administrator credentials."
		c.Fix = "Restore database access and retry the health check"
		return c
	}
	found := false
	for _, a := range rows {
		if a.Kind != account.KindUser || a.Status != account.StatusActive || (a.Role != "admin" && (handle == "" || a.Handle != handle)) {
			continue
		}
		found = true
		if a.PasswordHash == "" {
			continue
		} // No local password login.
		err := bcrypt.CompareHashAndPassword([]byte(a.PasswordHash), []byte("changeme"))
		if err == nil {
			c.Status, c.Detail = "fail", "An active administrator still uses the default password."
			c.Fix = "Change that account's password in Profile settings; .env only sets the password for a new bootstrap account"
			return c
		}
		if !errors.Is(err, bcrypt.ErrMismatchedHashAndPassword) {
			c.Status, c.Detail = "fail", "Cannot verify an administrator's stored password hash."
			c.Fix = "Repair the account credentials using password recovery"
			return c
		}
	}
	if !found {
		c.Status, c.Detail = "warn", "No active administrator account was found."
		c.Fix = "Create a bootstrap administrator with TRADERA_ADMIN_PASSWORD, then restart"
		return c
	}
	c.Status, c.Detail = "ok", "No active administrator uses the default password"
	return c
}
