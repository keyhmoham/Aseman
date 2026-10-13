// Package invitation defines space invitations.
package invitation

import (
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
)

// Status of an invitation.
type Status string

const (
	StatusPending  Status = "pending"
	StatusAccepted Status = "accepted"
	StatusDeclined Status = "declined"
	StatusRevoked  Status = "revoked"
)

// Invitation invites an account into a space (optionally a room).
type Invitation struct {
	entity.Entity
	SpaceID   identity.ID     `db:"space_id" json:"space_id"`
	RoomID    identity.ID     `db:"room_id" json:"room_id,omitempty"`
	InviterID identity.ID     `db:"inviter_id" json:"inviter_id"`
	InviteeID identity.ID     `db:"invitee_id" json:"invitee_id"`
	Role      membership.Role `db:"role" json:"role"`
	Token     string          `db:"token" json:"token,omitempty"`
	Status    Status          `db:"status" json:"status"`
	ExpiresAt time.Time       `db:"expires_at" json:"expires_at,omitempty"`
}
