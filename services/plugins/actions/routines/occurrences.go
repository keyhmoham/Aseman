package routine

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	rt "github.com/aseman/aseman/plugins/actions/routines/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/models/execution"
)

func (s *Service) startOccurrence(ctx context.Context, r *rt.Routine) (*rt.Occurrence, error) {
	idString := r.ActiveRunID
	if idString == "" {
		idString = repo.ExecutionKey(r.ID.String() + "/" + r.NextRunAt.UTC().Format("2006-01-02T15:04:05.999999999Z07:00"))
	}
	id, err := identity.Parse(idString)
	if err != nil {
		return nil, err
	}
	var existing rt.Occurrence
	err = s.R.Get(ctx, "routine_runs", id, &existing)
	if err == nil {
		if r.RetryCount == 0 || existing.Status != "failed" {
			return nil, errs.Conflict("scheduled occurrence already executed or uncertain")
		}
		existing.Attempt++
		existing.Status = "running"
		existing.UpdatedAt = s.now().UTC()
		if err := s.R.Update(ctx, "routine_runs", id, &existing); err != nil {
			return nil, err
		}
		return &existing, nil
	}
	if errs.CodeOf(err) != errs.CodeNotFound {
		return nil, err
	}
	now := s.now().UTC()
	occurrence := &rt.Occurrence{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, RoutineID: r.ID, SpaceID: r.SpaceID, RoomID: r.RoomID, CreatorID: r.CreatorID, ScheduledAt: r.NextRunAt, Status: "running", Attempt: 1, Target: r.Target, Task: r.Task}
	if err := s.R.CreateID(ctx, "routine_runs", id, occurrence); err != nil {
		return nil, err
	}
	return occurrence, nil
}

func (s *Service) retrySafe(ctx context.Context, id identity.ID) bool {
	var events []execution.Event
	if err := s.R.List(ctx, "execution_events", database.Filter{Equal: map[string]any{"run_id": id.String()}, Limit: 1}, &events); err != nil {
		return false
	}
	return len(events) == 0
}

// recoverOccurrence advances a committed outcome without redispatching it.
func (s *Service) recoverOccurrence(ctx context.Context, r *rt.Routine) error {
	idString := r.ActiveRunID
	if idString == "" {
		idString = repo.ExecutionKey(r.ID.String() + "/" + r.NextRunAt.UTC().Format(time.RFC3339Nano))
	}
	id, err := identity.Parse(idString)
	if err != nil {
		return err
	}
	var occurrence rt.Occurrence
	err = s.R.Get(ctx, "routine_runs", id, &occurrence)
	if errs.CodeOf(err) == errs.CodeNotFound {
		r.Status = rt.Active
	} else if err != nil {
		return err
	} else if occurrence.Status == "done" || occurrence.Status == "failed" {
		r.LastResult = occurrence.Result
		r.LastRunAt = &occurrence.UpdatedAt
		if r.Type == rt.Periodic {
			r.Status = rt.Active
			r.NextRunAt = s.now().UTC().Add(time.Duration(max(r.IntervalSec, 1)) * time.Second)
		} else if occurrence.Status == "done" {
			r.Status = rt.Done
		} else {
			r.Status = rt.Failed
		}
		r.ActiveRunID = ""
		r.RetryCount = 0
		r.RetryAt = nil
	} else {
		r.Status = rt.Paused
		r.LastResult = "Interrupted occurrence: inspect side effects before resuming."
	}
	r.UpdatedAt = s.now().UTC()
	_, err = s.R.CompareAndSwap(ctx, "routines", r.ID.String(), map[string]any{"status": string(rt.Running)}, r)
	return err
}
