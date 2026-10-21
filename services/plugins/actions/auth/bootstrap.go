package auth

import (
	"context"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Bootstrap creates the configured administrator using the namespace's normal registration path
// only if no administrator account already exists.
func (s *Service) Bootstrap(ctx context.Context) error {
	if pass := s.K.Env()["admin_password"]; pass != "" {
		handle := s.K.Env()["admin_handle"]
		if handle == "" {
			handle = "admin"
		}

		// If an account with the default admin handle already exists, nothing to bootstrap.
		if _, err := s.Account(ctx, handle); err == nil {
			return nil
		} else if errs.CodeOf(err) != errs.CodeNotFound {
			return err
		}

		// If any administrator account already exists (e.g. username was changed or custom admin created),
		// do not recreate the default bootstrap admin account.
		if s.hasAdminAccount(ctx) {
			return nil
		}

		if _, _, _, err := s.Register(ctx, handle, handle+"@localhost", pass); err != nil {
			return err
		}
		s.L.Info("admin account bootstrapped", "handle", handle)
	}
	return nil
}

func (s *Service) hasAdminAccount(ctx context.Context) bool {
	var admins []account.Account
	if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"role": "admin"}, Limit: 1}, &admins); err == nil && len(admins) > 0 {
		return true
	}
	return false
}
