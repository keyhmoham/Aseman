// Package account defines the authentication principal: a user or a bot.
package account

import (
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
)

// Kind distinguishes human users from bots (VMs operating in the network).
type Kind string

const (
	KindUser Kind = "user"
	KindBot  Kind = "bot"
)

// Status of an account.
type Status string

const (
	StatusActive   Status = "active"
	StatusDisabled Status = "disabled"
	StatusPending  Status = "pending"
)

// Account is the root identity record. Users and bots both have one.
type Account struct {
	entity.Entity
	Kind           Kind        `db:"kind" json:"kind"`
	Handle         string      `db:"handle" json:"handle"`
	Email          string      `db:"email" json:"email"`
	Role           string      `db:"role" json:"role"`
	RecoveryKeyEnc string      `db:"recovery_key_enc" json:"-"`
	EmailVerified  bool        `db:"email_verified" json:"email_verified"`
	PasswordHash   string      `db:"password_hash" json:"-"`
	PublicKey      string      `db:"public_key" json:"public_key,omitempty"`
	PrivateKeyEnc  string      `db:"private_key_enc" json:"-"`
	Status         Status      `db:"status" json:"status"`
	MetadataID     identity.ID `db:"metadata_id" json:"metadata_id"`
	LastSeen       time.Time   `db:"last_seen" json:"last_seen,omitempty"`
}

// New assembles a fresh account record.
func New(id identity.ID, kind Kind, handle, email string) *Account {
	return &Account{
		Entity: entity.Entity{ID: id},
		Kind:   kind,
		Handle: handle,
		Email:  email,
		Status: StatusActive,
	}
}

// IsBot reports whether the account is a bot.
func (a *Account) IsBot() bool { return a.Kind == KindBot }
