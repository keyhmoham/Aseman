package kernel

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"time"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/auth/models/session"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// Maintenance credentials are short-lived, previously verified administrator
// sessions. They grant only host control while the database is disconnected;
// ordinary actions always require the current database's session validation.
type maintenanceCredential struct {
	account account.Account
	expires time.Time
}

func tokenDigest(token string) string {
	digest := sha256.Sum256([]byte(token))
	return hex.EncodeToString(digest[:])
}
func (k *Kernel) Authenticate(ctx context.Context, token string, maintenance bool) (*account.Account, error) {
	if token == "" {
		return nil, errs.Unauthenticated("missing token")
	}
	digest := tokenDigest(token)
	if db := k.DB(); db != nil {
		r := &repo.Repo{DB: db}
		owner, err := helper.SessionAccount(ctx, r, token)
		if err != nil {
			k.mu.Lock()
			delete(k.credentials, digest)
			k.mu.Unlock()
			return nil, err
		}
		if owner.Kind == account.KindUser && owner.Handle == k.Env()["admin_handle"] {
			var sessions []session.Session
			if err := r.List(ctx, "sessions", database.Filter{Equal: map[string]any{"token_hash": digest}}, &sessions); err == nil && len(sessions) > 0 {
				expires := time.Now().Add(5 * time.Minute)
				if sessions[0].ExpiresAt.Before(expires) {
					expires = sessions[0].ExpiresAt
				}
				k.mu.Lock()
				for key, saved := range k.credentials {
					if time.Now().After(saved.expires) {
						delete(k.credentials, key)
					}
				}
				if len(k.credentials) >= 64 {
					oldest := ""
					oldestTime := time.Time{}
					for key, saved := range k.credentials {
						if oldest == "" || saved.expires.Before(oldestTime) {
							oldest = key
							oldestTime = saved.expires
						}
					}
					delete(k.credentials, oldest)
				}
				k.credentials[digest] = maintenanceCredential{account: *owner, expires: expires}
				k.mu.Unlock()
			}
		}
		return owner, nil
	}
	if maintenance {
		k.mu.RLock()
		saved, ok := k.credentials[digest]
		k.mu.RUnlock()
		if ok && time.Now().Before(saved.expires) && saved.account.Handle == k.Env()["admin_handle"] {
			owner := saved.account
			return &owner, nil
		}
	}
	return nil, errs.New(errs.CodeUnavailable, "session database unavailable")
}
func (k *Kernel) maintenanceAdmin(id identity.ID) bool {
	k.mu.RLock()
	defer k.mu.RUnlock()
	for _, credential := range k.credentials {
		if credential.account.ID == id && credential.account.Handle == k.env["admin_handle"] && time.Now().Before(credential.expires) {
			return true
		}
	}
	return false
}
