// Package turn owns accepted room work, distinct from workflow execution plans.
package turn

import (
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"time"
)

type Turn struct {
	entity.Entity
	SpaceID     identity.ID `db:"space_id" json:"space_id"`
	RoomID      identity.ID `db:"room_id" json:"room_id"`
	ActorID     identity.ID `db:"actor_id" json:"actor_id"`
	Submission  string      `db:"submission" json:"submission"`
	Fingerprint string      `db:"fingerprint" json:"-"`
	MessageID   string      `db:"message_id" json:"message_id"`
	Prompt      string      `db:"prompt" json:"prompt"`
	Seeds       []string    `db:"seeds" json:"seeds"`
	Attachments []string    `db:"attachments" json:"attachments"`
	Status      string      `db:"status" json:"status"`
	Error       string      `db:"error" json:"error,omitempty"`
	StartedAt   time.Time   `db:"started_at" json:"started_at,omitempty"`
	EndedAt     time.Time   `db:"ended_at" json:"ended_at,omitempty"`
	LeaseUntil  time.Time   `db:"lease_until" json:"-"`
	// Spans is where the turn's time went (admin project log).
	Spans []Span `db:"spans" json:"spans,omitempty"`
}

// Span is one timed phase of a turn: what it was, the detail worth reading, when
// it began and how long it took.
type Span struct {
	Name   string    `json:"name"`
	Detail string    `json:"detail,omitempty"`
	Start  time.Time `json:"start"`
	Ms     int64     `json:"ms"`
}
