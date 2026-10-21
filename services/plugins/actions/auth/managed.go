package auth

import (
	"context"
	"strings"
	"time"

	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/support/helper"
)

// managedEmailDomain names the mailbox of an account made for someone who
// does not sign in to it themselves; the reserved .invalid domain never
// receives mail.
const managedEmailDomain = "managed.tradera.invalid"

// CreateManagedAccount registers an ordinary user account that an
// administrator — or the admins space's tool working for one — makes for
// someone else (such as a trader whose posts are imported). No one reads its mailbox,
// so it is active and verified at once; with no email given it gets a
// placeholder one. The administrator role is never granted here.
func (s *Service) CreateManagedAccount(ctx context.Context, handle, email, password string) (*account.Account, error) {
	clean, err := helper.NormalizeHandle(handle)
	if err != nil {
		return nil, err
	}
	if clean == s.K.Env()["admin_handle"] {
		return nil, errs.AlreadyExists("bootstrap administrator handle is reserved")
	}
	email = strings.TrimSpace(email)
	if email == "" {
		email = clean + "@" + managedEmailDomain
	}
	acc, _, _, err := s.Register(ctx, clean, email, password)
	if err != nil {
		return nil, err
	}
	acc.Status, acc.EmailVerified, acc.Role = account.StatusActive, true, "user"
	acc.UpdatedAt = time.Now().UTC()
	if err := s.R.Update(ctx, "accounts", acc.ID, acc); err != nil {
		return nil, err
	}
	return acc, nil
}
