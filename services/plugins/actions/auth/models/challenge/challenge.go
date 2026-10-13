// Package challenge defines one-time codes that prove control of an account's
// email address (password reset).
package challenge

import (
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
)

// Purpose of a challenge.
type Purpose string

const (
	PurposePasswordReset     Purpose = "password_reset"
	PurposeEmailVerification Purpose = "email_verification"
)

// MaxAttempts bounds wrong guesses before a challenge is burned.
const MaxAttempts = 5

// Challenge is a single-use, short-lived code bound to an account and purpose.
// Only the code's hash is stored.
type Challenge struct {
	entity.Entity
	AccountID identity.ID `db:"account_id" json:"account_id"`
	Purpose   Purpose     `db:"purpose" json:"purpose"`
	CodeHash  string      `db:"code_hash" json:"-"`
	Attempts  int64       `db:"attempts" json:"attempts"`
	ExpiresAt time.Time   `db:"expires_at" json:"expires_at"`
	UsedAt    time.Time   `db:"used_at" json:"used_at,omitempty"`
}

// Open reports whether the challenge can still be redeemed at now.
func (c *Challenge) Open(now time.Time) bool {
	return c.UsedAt.IsZero() && now.Before(c.ExpiresAt) && c.Attempts < MaxAttempts
}
