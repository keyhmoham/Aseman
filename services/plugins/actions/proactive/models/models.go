// Package proactive holds the records of the proactive namespace: the Tasks
// a person sees (what needs them, what agents suggest, what agents work
// on), the mail verdicts triage made, each day's morning brief, and each
// person's background research and first-day state.
package proactive

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Task kinds.
const (
	KindNeedsYou   = "needs_you"
	KindSuggestion = "suggestion"
	KindWork       = "work"
)

// Task states.
const (
	StatusSuggested  = "suggested"
	StatusWorking    = "working"
	StatusNeedsInput = "needs_input"
	StatusReview     = "ready_for_review"
	StatusFailed     = "failed"
	StatusResolved   = "resolved"
	StatusHidden     = "hidden"
)

// Task is one row of a person's Tasks.
type Task struct {
	entity.Entity
	OwnerID string `db:"owner_id" json:"owner_id"`
	SpaceID string `db:"space_id" json:"space_id"`
	RoomID  string `db:"room_id" json:"room_id,omitempty"`
	Kind    string `db:"kind" json:"kind"`
	Status  string `db:"status" json:"status"`
	Title   string `db:"title" json:"title"`
	Detail  string `db:"detail" json:"detail,omitempty"`
	Reason  string `db:"reason" json:"reason,omitempty"`
	// Source is what it came from: "mail:<id>", "agent:<name>", "brief".
	Source string `db:"source" json:"source,omitempty"`
	// Color is the room's, so a task wears its channel's colour.
	Color string `db:"color" json:"color,omitempty"`
	// TurnID is the run working on it; MessageID the message it opened at.
	TurnID    string    `db:"turn_id" json:"turn_id,omitempty"`
	MessageID string    `db:"message_id" json:"message_id,omitempty"`
	Summary   string    `db:"summary" json:"summary,omitempty"`
	Error     string    `db:"error" json:"error,omitempty"`
	Retryable bool      `db:"retryable" json:"retryable,omitempty"`
	StartedAt time.Time `db:"started_at" json:"started_at,omitempty"`
	DoneAt    time.Time `db:"done_at" json:"done_at,omitempty"`
}

// MailVerdict is triage's sorting of one message for one person.
type MailVerdict struct {
	entity.Entity
	OwnerID   string    `db:"owner_id" json:"owner_id"`
	MailID    string    `db:"mail_id" json:"mail_id"`
	Verdict   string    `db:"verdict" json:"verdict"`
	Reason    string    `db:"reason" json:"reason"`
	DecidedBy string    `db:"decided_by" json:"decided_by"`
	From      string    `db:"sender" json:"from"`
	Subject   string    `db:"subject" json:"subject"`
	Date      time.Time `db:"date" json:"date"`
}

// Brief is one person's morning brief for one day. Its id is derived from
// the person and the day, so however many tabs and devices ask, it is made
// once.
type Brief struct {
	entity.Entity
	OwnerID string `db:"owner_id" json:"owner_id"`
	Day     string `db:"day" json:"day"`
	SpaceID string `db:"space_id" json:"space_id"`
	RoomID  string `db:"room_id" json:"room_id,omitempty"`
	// Content is the brief's structure (BriefContent) as JSON.
	Content map[string]any `db:"content" json:"content"`
	Posted  bool           `db:"posted" json:"posted"`
}

// Person is a person's proactive settings and state. Its id is theirs.
type Person struct {
	entity.Entity
	Timezone string `db:"timezone" json:"timezone,omitempty"`
	// Research: background check-ins over connected apps, read-only.
	Research       bool      `db:"research" json:"research"`
	ResearchOptOut bool      `db:"research_opt_out" json:"research_opt_out,omitempty"`
	IntervalHours  int64     `db:"interval_hours" json:"interval_hours"`
	LastResearchAt time.Time `db:"last_research_at" json:"last_research_at,omitempty"`
	NextResearchAt time.Time `db:"next_research_at" json:"next_research_at,omitempty"`
	LastResult     string    `db:"last_result" json:"last_result,omitempty"`
	// BriefOff stops the morning brief.
	BriefOff bool `db:"brief_off" json:"brief_off,omitempty"`
	// FirstDayAt is when the first-day greeting ran.
	FirstDayAt time.Time `db:"first_day_at" json:"first_day_at,omitempty"`
	FirstSeen  time.Time `db:"first_seen" json:"first_seen,omitempty"`
}

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

func base(fields ...database.Field) []database.Field {
	return append([]database.Field{f("id", database.KindString), f("created_at", database.KindTime), f("updated_at", database.KindTime)}, fields...)
}

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model {
	s, t, b, j, i := database.KindString, database.KindTime, database.KindBool, database.KindJSON, database.KindInt64
	return []database.Model{
		{Name: "tasks", Table: "tasks", Fields: base(f("owner_id", s), f("space_id", s), f("room_id", s), f("kind", s), f("status", s),
			f("title", s), f("detail", s), f("reason", s), f("source", s), f("color", s), f("turn_id", s), f("message_id", s),
			f("summary", s), f("error", s), f("retryable", b), f("started_at", t), f("done_at", t))},
		{Name: "mail_verdicts", Table: "mail_verdicts", Fields: base(f("owner_id", s), f("mail_id", s), f("verdict", s), f("reason", s),
			f("decided_by", s), f("sender", s), f("subject", s), f("date", t))},
		{Name: "briefs", Table: "briefs", Fields: base(f("owner_id", s), f("day", s), f("space_id", s), f("room_id", s), f("content", j), f("posted", b))},
		{Name: "proactive_people", Table: "proactive_people", Fields: base(f("timezone", s), f("research", b), f("research_opt_out", b),
			f("interval_hours", i), f("last_research_at", t), f("next_research_at", t), f("last_result", s), f("brief_off", b),
			f("first_day_at", t), f("first_seen", t))},
	}
}
