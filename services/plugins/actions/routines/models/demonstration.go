package routine

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Demonstration states.
const (
	DemoRecording = "recording"
	DemoDrafted   = "drafted"
	DemoSaved     = "saved"
	DemoDiscarded = "discarded"
	DemoFailed    = "failed"
)

// DemoMaxDuration is the longest a recording runs before it stops itself.
const DemoMaxDuration = 10 * time.Minute

// Demonstration is a person doing a task once on the project computer while
// it records, and the skill drafted from it: kept as a project skill and,
// with a schedule, an ordinary routine.
type Demonstration struct {
	entity.Entity
	SpaceID      string    `db:"space_id" json:"space_id"`
	RoomID       string    `db:"room_id" json:"room_id,omitempty"`
	OwnerID      string    `db:"owner_id" json:"owner_id"`
	Status       string    `db:"status" json:"status"`
	StartedAt    time.Time `db:"started_at" json:"started_at"`
	StoppedAt    time.Time `db:"stopped_at" json:"stopped_at,omitempty"`
	Trace        string    `db:"trace" json:"trace,omitempty"`
	Title        string    `db:"title" json:"title,omitempty"`
	Instructions string    `db:"instructions" json:"instructions,omitempty"`
	Inputs       []string  `db:"inputs" json:"inputs,omitempty"`
	// Schedule is what the draft suggests ("daily 09:00", "" for none).
	Schedule  string `db:"schedule" json:"schedule,omitempty"`
	SkillPath string `db:"skill_path" json:"skill_path,omitempty"`
	RoutineID string `db:"routine_id" json:"routine_id,omitempty"`
	Error     string `db:"error" json:"error,omitempty"`
}

func demonstrations() database.Model {
	s, t, j := database.KindString, database.KindTime, database.KindJSON
	return database.Model{Name: "demonstrations", Table: "demonstrations", Fields: []database.Field{
		f("id", s), f("created_at", t), f("updated_at", t), f("space_id", s), f("room_id", s), f("owner_id", s), f("status", s),
		f("started_at", t), f("stopped_at", t), f("trace", s), f("title", s), f("instructions", s), f("inputs", j), f("schedule", s),
		f("skill_path", s), f("routine_id", s), f("error", s)}}
}
