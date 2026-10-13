// Package routine models task timing management: per-room delayed and periodic
// routines that fire a task (dispatched to an agent/tool or recorded) on a
// schedule. Each space room keeps its own routine set.
package routine

import (
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
)

// Type of a routine.
type Type string

const (
	// Delayed runs the task once after a custom delay.
	Delayed Type = "delayed"
	// Periodic runs the task repeatedly on an interval.
	Periodic Type = "periodic"
)

// Status of a routine.
type Status string

const (
	Active   Status = "active"
	Running  Status = "running"
	Retrying Status = "retrying"
	Done     Status = "done"
	Paused   Status = "paused"
	Failed   Status = "failed"
)

// Routine is a timed task scoped to a (space, room).
type Routine struct {
	entity.Entity
	SpaceID     identity.ID `db:"space_id" json:"space_id"`
	RoomID      identity.ID `db:"room_id" json:"room_id"`
	CreatorID   identity.ID `db:"creator_id" json:"creator_id"`
	Name        string      `db:"name" json:"name"`
	Type        Type        `db:"type" json:"type"`
	Target      string      `db:"target" json:"target,omitempty"` // bot id or empty
	Task        string      `db:"task" json:"task"`
	DelaySec    int64       `db:"delay_sec" json:"delay_sec,omitempty"`
	IntervalSec int64       `db:"interval_sec" json:"interval_sec,omitempty"`
	// At and Timezone make a periodic routine a daily one: it runs every day at
	// At ("HH:MM") on the wall clock of Timezone (an IANA name), which keeps its
	// hour across daylight-saving changes.
	At          string     `db:"at" json:"at,omitempty"`
	Timezone    string     `db:"timezone" json:"timezone,omitempty"`
	ActiveRunID string     `db:"active_run_id" json:"active_run_id,omitempty"`
	RetryAt     *time.Time `db:"retry_at" json:"retry_at,omitempty"`
	RetryCount  int64      `db:"retry_count" json:"retry_count"`
	NextRunAt   time.Time  `db:"next_run_at" json:"next_run_at"`
	LastRunAt   *time.Time `db:"last_run_at" json:"last_run_at,omitempty"`
	LastResult  string     `db:"last_result" json:"last_result,omitempty"`
	Status      Status     `db:"status" json:"status"`
}

// NextDaily is the first time after [after] that the wall clock of [tz] reads
// [at] ("HH:MM"). Computed on the calendar, not by adding 24 hours, so a daily
// routine keeps its hour when clocks change.
func NextDaily(at, tz string, after time.Time) (time.Time, error) {
	loc := time.UTC
	if strings.TrimSpace(tz) != "" {
		l, err := time.LoadLocation(strings.TrimSpace(tz))
		if err != nil {
			return time.Time{}, errs.InvalidArgument("unknown timezone " + tz + " (use an IANA name such as Europe/London)")
		}
		loc = l
	}
	t, err := time.Parse("15:04", strings.TrimSpace(at))
	if err != nil {
		return time.Time{}, errs.InvalidArgument("at must be a time like 09:00")
	}
	local := after.In(loc)
	next := time.Date(local.Year(), local.Month(), local.Day(), t.Hour(), t.Minute(), 0, 0, loc)
	for !next.After(after) {
		next = time.Date(next.Year(), next.Month(), next.Day()+1, t.Hour(), t.Minute(), 0, 0, loc)
	}
	return next.UTC(), nil
}
