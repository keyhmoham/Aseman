// Package execution holds the records spaces keeps about agent work: files an
// agent delivered during a run (artifacts). Tool events use the shared
// vmm execution.Event model.
package execution

import (
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
)

// Artifact binds a delivered file to the run and agent that produced it.
type Artifact struct {
	entity.Entity
	FileID    identity.ID `db:"file_id" json:"file_id"`
	SpaceID   identity.ID `db:"space_id" json:"space_id"`
	RoomID    identity.ID `db:"room_id" json:"room_id"`
	RunID     string      `db:"run_id" json:"run_id"`
	StepID    string      `db:"step_id" json:"step_id"`
	AttemptID string      `db:"attempt_id" json:"attempt_id"`
	AgentID   string      `db:"agent_id" json:"agent_id"`
	Delivered bool        `db:"delivered" json:"delivered"`
}
