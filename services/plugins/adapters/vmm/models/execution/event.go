package execution

import "time"

// ExecutionEvent records one host-attributed tool operation.
type Event struct {
	ID        string    `db:"id" json:"id"`
	SpaceID   string    `db:"space_id" json:"space_id"`
	RoomID    string    `db:"room_id" json:"room_id"`
	RunID     string    `db:"run_id" json:"run_id"`
	StepID    string    `db:"step_id" json:"step_id"`
	AttemptID string    `db:"attempt_id" json:"attempt_id"`
	AgentID   string    `db:"agent_id" json:"agent_id"`
	AgentName string    `db:"agent_name" json:"agent_name"`
	Tool      string    `db:"tool" json:"tool"`
	Args      string    `db:"args" json:"args"`
	Result    string    `db:"result" json:"result"`
	Status    string    `db:"status" json:"status"`
	At        time.Time `db:"at" json:"at"`
}
