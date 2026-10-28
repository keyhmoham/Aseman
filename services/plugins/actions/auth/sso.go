package auth

import (
	"context"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/auth/models/session"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// ssoRequired refuses a sign-in that is not single sign-on for an email
// whose domain must use it (the enterprise namespace decides; without it,
// nothing is required).
func (s *Service) ssoRequired(ctx context.Context, email, provider string) error {
	if strings.HasPrefix(provider, "sso:") || s.K == nil {
		return nil
	}
	if _, err := s.K.Resolve("service/enterprise"); err != nil {
		return nil
	}
	var name string
	if err := bridge.Invoke(ctx, s.K, "enterprise", "RequiredProvider", []any{ctx, email}, &name); err != nil || name == "" {
		return nil
	}
	return errs.Unauthenticated("your organization signs in with " + name + ": use \"Continue with SSO\"")
}

// RevokeSessions ends every session of an account (it was deprovisioned).
func (s *Service) RevokeSessions(ctx context.Context, owner identity.ID) (int, error) {
	var rows []session.Session
	if err := s.R.List(ctx, "sessions", database.Filter{Equal: map[string]any{"owner_id": owner.String()}}, &rows); err != nil {
		return 0, err
	}
	for i := range rows {
		_ = s.R.Delete(ctx, "sessions", rows[i].ID)
	}
	return len(rows), nil
}

// SetAccess changes whether an account may sign in and whether it
// administers the node: the directory (SCIM) and single sign-on groups
// decide these. An empty status or role keeps it. The bootstrap
// administrator is never demoted.
func (s *Service) SetAccess(ctx context.Context, id identity.ID, status account.Status, role string) (*account.Account, error) {
	var acc account.Account
	if err := s.R.Get(ctx, "accounts", id, &acc); err != nil {
		return nil, err
	}
	if acc.Kind != account.KindUser {
		return nil, errs.InvalidArgument("only a person's access changes")
	}
	if acc.Handle == s.K.Env()["admin_handle"] && (role == "user" || status == account.StatusDisabled) {
		return &acc, nil
	}
	if status != "" {
		acc.Status = status
		if status == account.StatusActive {
			acc.EmailVerified = true
		}
	}
	if role != "" {
		acc.Role = role
	}
	acc.UpdatedAt = time.Now().UTC()
	return &acc, s.R.Update(ctx, "accounts", id, &acc)
}
