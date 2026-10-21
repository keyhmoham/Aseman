// Package membership models the relationship between an account and a space,
// including per-room scoped permissions.
package membership

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
)

// Role in a space.
type Role string

const (
	RoleOwner  Role = "owner"
	RoleAdmin  Role = "admin"
	RoleMember Role = "member"
	RoleBot    Role = "bot"
	RoleGuest  Role = "guest"
	RoleViewer Role = "viewer"
)

// ValidRole rejects misspellings rather than granting member permissions.
func ValidRole(role Role) bool {
	switch role {
	case RoleOwner, RoleAdmin, RoleMember, RoleBot, RoleGuest, RoleViewer:
		return true
	}
	return false
}

// Membership binds an account to a space (space-scoped) and optionally to
// rooms (room-scoped rows carry room membership permissions).
type Membership struct {
	entity.Entity
	SpaceID  identity.ID `db:"space_id" json:"space_id"`
	RoomID   identity.ID `db:"room_id" json:"room_id,omitempty"` // zero => space-level
	MemberID identity.ID `db:"member_id" json:"member_id"`
	Role     Role        `db:"role" json:"role"`
	// Permissions overrides/grants additional permissions. Empty means the
	// role defaults apply.
	Permissions []string  `db:"permissions" json:"permissions,omitempty"`
	JoinedAt    time.Time `db:"joined_at" json:"joined_at"`
}

// HasPermission reports a direct grant on the membership row.
func (m *Membership) HasPermission(p string) bool {
	for _, g := range m.Permissions {
		if g == p || g == "*" {
			return true
		}
	}
	return false
}

// CanManage reports whether the role may administer other non-owner members.
func (m *Membership) CanManage() bool { return m.Role == RoleOwner || m.Role == RoleAdmin }

// IsSpaceLevel reports whether this row is a space-level membership.
func (m *Membership) IsSpaceLevel() bool { return m.RoomID.IsZero() }

// IsOwner reports ownership.
func (m *Membership) IsOwner() bool { return m.Role == RoleOwner }
