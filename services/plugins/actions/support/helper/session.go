package helper

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/auth/models/session"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// SessionAccount verifies a foundation credential independently of whether
// the authentication action namespace is currently loaded.
func SessionAccount(ctx context.Context, r *repo.Repo, token string) (*account.Account, error) {
	if token == "" {
		return nil, errs.Unauthenticated("missing token")
	}
	digest := sha256.Sum256([]byte(token))
	var sessions []session.Session
	if err := r.List(ctx, "sessions", database.Filter{Equal: map[string]any{"token_hash": hex.EncodeToString(digest[:])}}, &sessions); err != nil || len(sessions) == 0 {
		return nil, errs.Unauthenticated("invalid session")
	}
	credential := sessions[0]
	if time.Now().After(credential.ExpiresAt) {
		_ = r.Delete(ctx, "sessions", credential.ID)
		return nil, errs.Unauthenticated("session expired")
	}
	var owner account.Account
	if err := r.Get(ctx, "accounts", credential.OwnerID, &owner); err != nil {
		return nil, errs.Unauthenticated("account not found")
	}
	if owner.Status == account.StatusDisabled {
		return nil, errs.Unauthenticated("account disabled")
	}
	now := time.Now().UTC()
	if owner.LastSeen.IsZero() || now.Sub(owner.LastSeen) > time.Minute {
		owner.LastSeen = now
		_ = r.Update(ctx, "accounts", owner.ID, &owner)
	}
	return &owner, nil
}
