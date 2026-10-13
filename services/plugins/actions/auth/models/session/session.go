// Package session defines authentication sessions and API tokens.
package session

import (
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
)

// Kind of session.
type Kind string

const (
	KindSession  Kind = "session" // interactive login session
	KindAPIToken Kind = "api_token"
)

// Session is an issued credential bound to an account.
type Session struct {
	entity.Entity
	OwnerID    identity.ID `db:"owner_id" json:"owner_id"`
	TokenHash  string      `db:"token_hash" json:"-"`
	Kind       Kind        `db:"kind" json:"kind"`
	ExpiresAt  time.Time   `db:"expires_at" json:"expires_at"`
	LastSeenAt time.Time   `db:"last_seen_at" json:"last_seen_at,omitempty"`
	Meta       string      `db:"meta" json:"meta,omitempty"` // JSON (ip, user agent)
}
