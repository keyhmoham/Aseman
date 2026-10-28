package governance

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// VaultSecret is a credential a person typed into a secret box. The value is
// sealed to its record and never returned by any action; agents name it as
// {{secret:name}} and the node puts the value in where it is used.
type VaultSecret struct {
	entity.Entity
	OwnerID    string    `db:"owner_id" json:"owner_id"`
	SpaceID    string    `db:"space_id" json:"space_id"`
	Name       string    `db:"name" json:"name"`
	Site       string    `db:"site" json:"site,omitempty"`
	Sealed     string    `db:"sealed" json:"-"`
	Length     int64     `db:"length" json:"length"`
	LastUsedAt time.Time `db:"last_used_at" json:"last_used_at,omitempty"`
}

// Secret request states.
const (
	SecretPending  = "pending"
	SecretSupplied = "supplied"
	SecretDeclined = "declined"
	SecretExpired  = "expired"
)

// SecretRequest is an agent asking a person for a credential through a masked
// box. The transcript only ever shows that it was asked and answered.
type SecretRequest struct {
	entity.Entity
	SpaceID   string    `db:"space_id" json:"space_id"`
	RoomID    string    `db:"room_id" json:"room_id,omitempty"`
	AgentID   string    `db:"agent_id" json:"agent_id,omitempty"`
	AgentName string    `db:"agent_name" json:"agent_name,omitempty"`
	ActorID   string    `db:"actor_id" json:"actor_id"`
	Name      string    `db:"name" json:"name"`
	Reason    string    `db:"reason" json:"reason"`
	Site      string    `db:"site" json:"site,omitempty"`
	Status    string    `db:"status" json:"status"`
	SecretID  string    `db:"secret_id" json:"secret_id,omitempty"`
	ExpiresAt time.Time `db:"expires_at" json:"expires_at"`
}

// Egress modes of a project computer.
const (
	EgressAllowAll     = "allow_all"
	EgressDefaultsPlus = "defaults_plus_allowlist"
	EgressAllowlist    = "allowlist_only"
	EgressDenyAll      = "deny_all"
)

// EgressPolicy is where a project's computer may connect. Its id is the
// project's.
type EgressPolicy struct {
	entity.Entity
	Mode      string   `db:"mode" json:"mode"`
	Allow     []string `db:"allow" json:"allow"`
	UpdatedBy string   `db:"updated_by" json:"updated_by,omitempty"`
}

// Handover states.
const (
	HandoverRequested  = "requested"
	HandoverControlled = "controlled"
	HandoverReleased   = "released"
)

// Handover is who holds a project's computer: its agents, or a person who
// took control (because an agent asked for help, or on their own).
type Handover struct {
	entity.Entity
	SpaceID      string    `db:"space_id" json:"space_id"`
	RoomID       string    `db:"room_id" json:"room_id,omitempty"`
	Status       string    `db:"status" json:"status"`
	AgentID      string    `db:"agent_id" json:"agent_id,omitempty"`
	AgentName    string    `db:"agent_name" json:"agent_name,omitempty"`
	Reason       string    `db:"reason" json:"reason,omitempty"`
	URL          string    `db:"url" json:"url,omitempty"`
	ControllerID string    `db:"controller_id" json:"controller_id,omitempty"`
	TakenAt      time.Time `db:"taken_at" json:"taken_at,omitempty"`
	ReleasedAt   time.Time `db:"released_at" json:"released_at,omitempty"`
	Note         string    `db:"note" json:"note,omitempty"`
}

func vaultSecrets() database.Model {
	return database.Model{Name: "vault_secrets", Table: "vault_secrets", Fields: base(
		f("owner_id", database.KindString), f("space_id", database.KindString), f("name", database.KindString), f("site", database.KindString),
		f("sealed", database.KindString), f("length", database.KindInt64), f("last_used_at", database.KindTime))}
}

func secretRequests() database.Model {
	return database.Model{Name: "secret_requests", Table: "secret_requests", Fields: base(
		f("space_id", database.KindString), f("room_id", database.KindString), f("agent_id", database.KindString), f("agent_name", database.KindString),
		f("actor_id", database.KindString), f("name", database.KindString), f("reason", database.KindString), f("site", database.KindString),
		f("status", database.KindString), f("secret_id", database.KindString), f("expires_at", database.KindTime))}
}

func egressPolicies() database.Model {
	return database.Model{Name: "egress_policies", Table: "egress_policies", Fields: base(
		f("mode", database.KindString), f("allow", database.KindJSON), f("updated_by", database.KindString))}
}

func handovers() database.Model {
	return database.Model{Name: "computer_handovers", Table: "computer_handovers", Fields: base(
		f("space_id", database.KindString), f("room_id", database.KindString), f("status", database.KindString),
		f("agent_id", database.KindString), f("agent_name", database.KindString), f("reason", database.KindString), f("url", database.KindString),
		f("controller_id", database.KindString), f("taken_at", database.KindTime), f("released_at", database.KindTime), f("note", database.KindString))}
}
