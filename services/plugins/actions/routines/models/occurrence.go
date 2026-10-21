package routine

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
)

// Occurrence retains the identity and outcome of one scheduled execution.
type Occurrence struct {
	entity.Entity
	RoutineID   identity.ID `db:"routine_id" json:"routine_id"`
	SpaceID     identity.ID `db:"space_id" json:"space_id"`
	RoomID      identity.ID `db:"room_id" json:"room_id"`
	CreatorID   identity.ID `db:"creator_id" json:"creator_id"`
	ScheduledAt time.Time   `db:"scheduled_at" json:"scheduled_at"`
	Status      string      `db:"status" json:"status"`
	Attempt     int64       `db:"attempt" json:"attempt"`
	Result      string      `db:"result" json:"result,omitempty"`
	Target      string      `db:"target" json:"target,omitempty"`
	Task        string      `db:"task" json:"task"`
}
