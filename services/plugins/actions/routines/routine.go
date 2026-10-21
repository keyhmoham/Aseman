// Package routine implements per-room task timing management: delayed tasks
// (fire once after a delay) and periodical tasks (fire on an interval). Tasks
// can run inline, be dispatched to another agent, or be passed to a tool. Each
// space room keeps its own routine set, surfaced in the room UI and as agent
// tools (routine_create / routine_list / routine_delete).
package routine

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	rt "github.com/aseman/aseman/plugins/actions/routines/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Manager is the interface spaces and the workflow orchestrator use to manage
// per-room routines.
type Manager interface {
	Create(ctx context.Context, spaceID, roomID, creator identity.ID, name string, typ rt.Type, target, task string, delaySec, intervalSec int64) (*rt.Routine, error)
	List(ctx context.Context, spaceID, roomID identity.ID) ([]rt.Routine, error)
	Delete(ctx context.Context, id identity.ID) error
}

// SpacesPort is the subset of the spaces service used to dispatch routine tasks
// to agents/tools.
type SpacesPort interface {
	AskBot(ctx context.Context, spaceID, botID identity.ID, body string, attachments []vmm.FileAttachment, history []vmm.ChatMessage) (string, error)
	SandboxExec(ctx context.Context, spaceID identity.ID, command string) (string, error)
}

// Service manages routines.
type Service struct {
	K           apiKernel
	R           *repo.Repo
	L           *logger.Logger
	Spaces      SpacesPort
	now         func() time.Time
	workerInit  sync.Once
	workerSlots chan struct{}
}

type apiKernel interface {
	NodeID() identity.NodeID
}

// NewService builds the routine service.
func NewService(k apiKernel, r *repo.Repo, log *logger.Logger) *Service {
	return &Service{K: k, R: r, L: log.Named("routine"), now: time.Now}
}

// Create adds a delayed or periodic routine for a (space, room).
func (s *Service) Create(ctx context.Context, spaceID, roomID, creator identity.ID, name string, typ rt.Type, target, task string, delaySec, intervalSec int64) (*rt.Routine, error) {
	if err := helper.CheckContextAccess(ctx, s.R, spaceID, roomID, true, "routine.write"); err != nil {
		return nil, err
	}
	if strings.TrimSpace(task) == "" {
		return nil, errs.InvalidArgument("task required")
	}
	if typ != rt.Delayed && typ != rt.Periodic {
		return nil, errs.InvalidArgument("type must be delayed or periodic")
	}
	now := s.now().UTC()
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	r := &rt.Routine{
		Entity:  entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		SpaceID: spaceID, RoomID: roomID, CreatorID: creator,
		Name: name, Type: typ, Target: target, Task: task,
		DelaySec: delaySec, IntervalSec: intervalSec,
		Status: rt.Active,
	}
	switch typ {
	case rt.Delayed:
		d := delaySec
		if d <= 0 {
			d = 60
		}
		r.DelaySec = d
		r.NextRunAt = now.Add(time.Duration(d) * time.Second)
	case rt.Periodic:
		d := intervalSec
		if d <= 0 {
			d = 3600
		}
		r.IntervalSec = d
		first := d
		if delaySec > 0 {
			// delay_sec positions the first run (e.g. "daily at 9:00"); the
			// interval repeats from there.
			first = delaySec
		}
		r.NextRunAt = now.Add(time.Duration(first) * time.Second)
	}
	if err := s.R.CreateID(ctx, "routines", id, r); err != nil {
		return nil, err
	}
	s.L.Info("routine created", "routine", id.String(), "type", typ, "room", roomID.String())
	return r, nil
}

// List returns the routines of a (space, room), newest first.
func (s *Service) List(ctx context.Context, spaceID, roomID identity.ID) ([]rt.Routine, error) {
	if err := helper.CheckContextAccess(ctx, s.R, spaceID, roomID, false); err != nil {
		return nil, err
	}
	var out []rt.Routine
	// Without a room, the project's routines in every room: a project's routine
	// card must show what an agent scheduled from any of its threads.
	eq := map[string]any{"space_id": spaceID.String()}
	if !roomID.IsZero() {
		eq["room_id"] = roomID.String()
	}
	if err := s.R.List(ctx, "routines", database.Filter{
		Equal:   eq,
		OrderBy: "created_at", Asc: false, Limit: 200,
	}, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// Get loads a routine by id.
func (s *Service) Get(ctx context.Context, id identity.ID) (*rt.Routine, error) {
	r := &rt.Routine{}
	if err := s.R.Get(ctx, "routines", id, r); err != nil {
		return nil, err
	}
	if err := helper.CheckContextAccess(ctx, s.R, r.SpaceID, r.RoomID, false); err != nil {
		return nil, err
	}
	return r, nil
}

// Update patches a routine's scheduling + task.
func (s *Service) Update(ctx context.Context, id identity.ID, name string, target, task string, delaySec, intervalSec int64) (*rt.Routine, error) {
	if err := s.R.RequireAtomicUpdates(); err != nil {
		return nil, err
	}
	r, err := s.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	if err := helper.CheckResourceManager(ctx, s.R, r.SpaceID, r.RoomID, r.CreatorID, "routine.write"); err != nil {
		return nil, err
	}
	if r.Status == rt.Running || r.Status == rt.Retrying {
		return nil, errs.Conflict("routine has an active occurrence; inspect its outcome before updating")
	}
	expected := map[string]any{"status": string(r.Status), "updated_at": r.UpdatedAt, "next_run_at": r.NextRunAt}
	now := s.now().UTC()
	if name != "" {
		r.Name = name
	}
	if target != "" {
		r.Target = target
	}
	if task != "" {
		r.Task = task
	}
	switch r.Type {
	case rt.Delayed:
		if delaySec > 0 {
			r.DelaySec = delaySec
		}
		if r.DelaySec <= 0 {
			r.DelaySec = 60
		}
		r.NextRunAt = now.Add(time.Duration(r.DelaySec) * time.Second)
	case rt.Periodic:
		if intervalSec > 0 {
			r.IntervalSec = intervalSec
			r.At, r.Timezone = "", "" // a new interval replaces a daily schedule
		}
		if r.IntervalSec <= 0 {
			r.IntervalSec = 3600
		}
		r.NextRunAt = now.Add(time.Duration(r.IntervalSec) * time.Second)
		if r.At != "" {
			if next, derr := rt.NextDaily(r.At, r.Timezone, now); derr == nil {
				r.NextRunAt = next
			}
		}
	}
	r.UpdatedAt = now
	changed, err := s.R.CompareAndSwap(ctx, "routines", id.String(), expected, r)
	if err != nil {
		return nil, err
	}
	if !changed {
		return nil, errs.Conflict("routine changed while updating; inspect its current state")
	}
	return r, nil
}

// Delete removes a routine.
func (s *Service) Delete(ctx context.Context, id identity.ID) error {
	r, err := s.Get(ctx, id)
	if err != nil {
		return err
	}
	if err := helper.CheckResourceManager(ctx, s.R, r.SpaceID, r.RoomID, r.CreatorID, "routine.write"); err != nil {
		return err
	}
	return s.R.Delete(ctx, "routines", id)
}

// Pause stops a routine from firing (kept for later resume).
func (s *Service) Pause(ctx context.Context, id identity.ID) (*rt.Routine, error) {
	r, err := s.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	if err := helper.CheckResourceManager(ctx, s.R, r.SpaceID, r.RoomID, r.CreatorID, "routine.write"); err != nil {
		return nil, err
	}
	r.Status = rt.Paused
	r.UpdatedAt = s.now().UTC()
	if err := s.R.Update(ctx, "routines", id, r); err != nil {
		return nil, err
	}
	return r, nil
}

// Resume reactivates a paused routine.
func (s *Service) Resume(ctx context.Context, id identity.ID) (*rt.Routine, error) {
	r, err := s.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	if err := helper.CheckResourceManager(ctx, s.R, r.SpaceID, r.RoomID, r.CreatorID, "routine.write"); err != nil {
		return nil, err
	}
	r.Status = rt.Active
	r.ActiveRunID = ""
	r.RetryAt = nil
	r.RetryCount = 0
	if r.NextRunAt.Before(s.now().UTC()) {
		r.NextRunAt = s.now().UTC()
	}
	r.UpdatedAt = s.now().UTC()
	if err := s.R.Update(ctx, "routines", id, r); err != nil {
		return nil, err
	}
	return r, nil
}

// Start runs the scheduler until the context is cancelled.
func (s *Service) Start(ctx context.Context) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := s.RunDue(ctx); err != nil {
				s.L.Warn("routine scheduler pass failed", "error", err)
			}
		}
	}
}

// RunDue fires every routine whose next run is due and reschedules it.
func (s *Service) RunDue(ctx context.Context) error {
	if err := s.R.RequireAtomicUpdates(); err != nil {
		return err
	}
	var all []rt.Routine
	if err := s.R.List(ctx, "routines", database.Filter{In: map[string][]any{"status": {string(rt.Active), string(rt.Running), string(rt.Retrying)}}}, &all); err != nil {
		return err
	}
	s.workerInit.Do(func() { s.workerSlots = make(chan struct{}, 4) })
	workers := s.workerSlots
	var wg sync.WaitGroup
	defer wg.Wait()
	var mu sync.Mutex
	var firstErr error
	for i := range all {
		r := all[i]
		// A routine whose project was deleted must not keep running: it would
		// wake agents, post messages and notify people for nothing.
		var sp struct {
			ID identity.ID `db:"id"`
		}
		if err := s.R.Get(ctx, "spaces", r.SpaceID, &sp); errs.CodeOf(err) == errs.CodeNotFound {
			s.L.Info("routine removed: its project no longer exists", "routine", r.ID.String())
			_ = s.R.Delete(ctx, "routines", r.ID)
			continue
		}
		if r.Status == rt.Retrying && (r.RetryAt == nil || r.RetryAt.After(s.now().UTC())) {
			continue
		}
		if r.Status == rt.Active && r.NextRunAt.After(s.now().UTC()) {
			continue
		}
		select {
		case workers <- struct{}{}:
		case <-ctx.Done():
			return ctx.Err()
		}
		acquired := true
		releaseSlot := func() {
			if acquired {
				<-workers
				acquired = false
			}
		}
		lease, err := repo.ClaimExecution(ctx, s.R, s.K.NodeID(), "routine/"+r.ID.String(), 11*time.Minute)
		if err != nil {
			releaseSlot()
			if errs.CodeOf(err) == errs.CodeConflict {
				continue
			}
			return err
		}
		if r.Status == rt.Running {
			err = s.recoverOccurrence(ctx, &r)
			_ = lease.Release(ctx, s.R)
			releaseSlot()
			if err != nil {
				return err
			}
			continue
		}
		original := r.NextRunAt
		priorStatus := r.Status
		if r.ActiveRunID == "" {
			r.ActiveRunID = repo.ExecutionKey(r.ID.String() + "/" + r.NextRunAt.UTC().Format(time.RFC3339Nano))
		}
		r.Status = rt.Running
		claimed, err := s.R.CompareAndSwap(ctx, "routines", r.ID.String(), map[string]any{"status": string(priorStatus), "next_run_at": original}, &r)
		if err != nil {
			_ = lease.Release(ctx, s.R)
			releaseSlot()
			return err
		}
		if !claimed {
			_ = lease.Release(ctx, s.R)
			releaseSlot()
			continue
		}
		wg.Add(1)
		go func(r rt.Routine, lease *repo.ExecutionLease) {
			defer wg.Done()
			defer func() { <-workers }()
			defer lease.Release(context.Background(), s.R)
			fireCtx, cancel := context.WithTimeout(ctx, 10*time.Minute)
			defer cancel()
			fireCtx = repo.WithExecutionLease(fireCtx, lease)
			fireCtx = helper.WithActor(vmm.WithRoom(fireCtx, r.RoomID.String()), r.CreatorID)
			fireCtx = vmm.WithExecution(fireCtx, vmm.Execution{ActorID: r.CreatorID.String(), SpaceID: r.SpaceID.String(), RoomID: r.RoomID.String(), RunID: repo.ExecutionKey(r.ID.String() + "/" + r.NextRunAt.UTC().Format(time.RFC3339Nano)), StepID: "routine", AttemptID: "0"})
			if err := s.fire(fireCtx, &r); err != nil {
				mu.Lock()
				if firstErr == nil {
					firstErr = err
				}
				mu.Unlock()
			}
		}(r, lease)
	}
	wg.Wait()
	return firstErr
}

// fire executes one routine and advances its schedule.
func (s *Service) fire(ctx context.Context, r *rt.Routine) error {
	now := s.now().UTC()
	start := time.Now()
	var current rt.Routine
	if err := s.R.Get(ctx, "routines", r.ID, &current); err != nil {
		return err
	}
	if current.Status != rt.Running || current.ActiveRunID != r.ActiveRunID {
		return errs.Conflict("routine changed before dispatch")
	}
	occurrence, occErr := s.startOccurrence(ctx, r)
	if occErr != nil {
		return occErr
	}
	// Retry uses the same immutable target/task snapshot and execution identity.
	execution := vmm.ExecutionFrom(ctx)
	execution.RunID = occurrence.ID.String()
	execution.AttemptID = fmt.Sprint(occurrence.Attempt)
	ctx = vmm.WithExecution(ctx, execution)
	copy := *r
	copy.Target = occurrence.Target
	copy.Task = occurrence.Task
	result, err := s.dispatch(ctx, &copy)
	occurrence.UpdatedAt = s.now().UTC()
	occurrence.Status = "done"
	occurrence.Result = result
	if err != nil {
		occurrence.Status = "failed"
		occurrence.Result = err.Error()
		if result != "" {
			occurrence.Result += "\n" + result
		}
	}
	if checkpointErr := s.R.Update(context.WithoutCancel(ctx), "routine_runs", occurrence.ID, occurrence); checkpointErr != nil {
		return checkpointErr
	}
	r.LastRunAt = &now
	r.LastResult = result
	if err != nil {
		r.LastResult = "error: " + occurrence.Result
		r.Status = rt.Failed
		s.L.Warn("routine failed", "routine", r.ID.String(), "error", err)
	}
	if r.Type == rt.Periodic {
		r.NextRunAt = nextPeriodicRun(r, s.now().UTC())
		r.Status = rt.Active
	} else if err == nil {
		r.Status = rt.Done
	}
	// Retry only unavailable dispatches with no recorded tool intent. Calls with
	// side effects require reconciliation; they are never blindly repeated.
	if err != nil && errs.CodeOf(err) == errs.CodeUnavailable && r.RetryCount < 2 && s.retrySafe(ctx, occurrence.ID) {
		r.RetryCount++
		retryAt := s.now().UTC().Add(time.Minute * time.Duration(1<<uint(r.RetryCount-1)))
		r.RetryAt = &retryAt
		r.Status = rt.Retrying
	} else {
		r.ActiveRunID = ""
		r.RetryAt = nil
		r.RetryCount = 0
	}
	r.UpdatedAt = now
	s.L.Info("routine fired", "routine", r.ID.String(), "name", r.Name, "took_ms", time.Since(start).Milliseconds())
	_, checkpointErr := s.R.CompareAndSwap(context.WithoutCancel(ctx), "routines", r.ID.String(), map[string]any{"status": string(rt.Running)}, r)
	return checkpointErr
}

// dispatch runs the routine's task: to an agent, a tool, or inline.
func (s *Service) dispatch(ctx context.Context, r *rt.Routine) (string, error) {
	if r.CreatorID.IsZero() {
		return "", errs.Permission("routine has no retained creator identity")
	}
	if err := helper.CheckSpaceAccess(ctx, s.R, r.CreatorID, r.SpaceID, r.RoomID, true, "routine.write"); err != nil {
		return "", err
	}
	if s.Spaces == nil {
		return "", errs.New(errs.CodeUnavailable, "routine dispatcher not wired")
	}
	if r.Target == "" {
		if runner, ok := s.Spaces.(interface {
			RunScheduledTask(context.Context, identity.ID, identity.ID, identity.ID, string) (string, error)
		}); ok {
			return runner.RunScheduledTask(ctx, r.SpaceID, r.RoomID, r.CreatorID, r.Task)
		}
		return "", errs.New(errs.CodeUnavailable, "default Aseman routine target unavailable")
	}
	botID, err := identity.Parse(r.Target)
	if err != nil {
		return "", errs.InvalidArgument("invalid target id")
	}
	record := bot.Bot{}
	if err := s.R.Get(ctx, "bots", botID, &record); err != nil {
		return "", err
	}
	if err := helper.CheckSpaceAccess(ctx, s.R, record.AccountID, r.SpaceID, r.RoomID, false); err != nil {
		return "", err
	}
	return s.Spaces.AskBot(ctx, r.SpaceID, botID, r.Task, nil, nil)
}

// toMap renders a routine for the API.
func (s *Service) toMap(r *rt.Routine) map[string]any {
	return map[string]any{
		"id": r.ID.String(), "space_id": r.SpaceID.String(), "room_id": r.RoomID.String(),
		"creator_id": r.CreatorID.String(), "name": r.Name, "type": string(r.Type),
		"target": r.Target, "task": r.Task,
		"delay_sec": r.DelaySec, "interval_sec": r.IntervalSec, "at": r.At, "timezone": r.Timezone,
		"next_run_at": r.NextRunAt, "last_run_at": r.LastRunAt,
		"last_result": r.LastResult, "status": string(r.Status),
		"created_at": r.CreatedAt, "updated_at": r.UpdatedAt,
	}
}

// nextPeriodicRun is when a periodic routine runs after a run. A daily one goes
// to its next wall-clock time. An interval one keeps its cadence from the time it
// was due (not from when the run finished), so "every 24 hours" does not creep
// later by the length of each run.
func nextPeriodicRun(r *rt.Routine, now time.Time) time.Time {
	if r.At != "" {
		if next, err := rt.NextDaily(r.At, r.Timezone, now); err == nil {
			return next
		}
	}
	d := time.Duration(r.IntervalSec) * time.Second
	if d <= 0 {
		d = time.Hour
	}
	next := r.NextRunAt.Add(d)
	if r.NextRunAt.IsZero() || next.Before(now) {
		// Missed runs are skipped, not replayed: keep the cadence, move to the future.
		next = now.Add(d)
		if !r.NextRunAt.IsZero() {
			missed := now.Sub(r.NextRunAt) / d
			next = r.NextRunAt.Add((missed + 1) * d)
		}
	}
	return next
}

// SetDaily makes a routine run every day at [at] ("HH:MM") in [tz], first at the
// next such time. It is how "every day at 9am" is scheduled.
func (s *Service) SetDaily(ctx context.Context, id identity.ID, at, tz string) (*rt.Routine, error) {
	if err := s.R.RequireAtomicUpdates(); err != nil {
		return nil, err
	}
	r, err := s.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	if err := helper.CheckResourceManager(ctx, s.R, r.SpaceID, r.RoomID, r.CreatorID, "routine.write"); err != nil {
		return nil, err
	}
	if r.Status == rt.Running || r.Status == rt.Retrying {
		return nil, errs.Conflict("routine has an active occurrence; inspect its outcome before updating")
	}
	next, err := rt.NextDaily(at, tz, s.now().UTC())
	if err != nil {
		return nil, err
	}
	expected := map[string]any{"status": string(r.Status), "updated_at": r.UpdatedAt, "next_run_at": r.NextRunAt}
	r.Type, r.IntervalSec, r.DelaySec = rt.Periodic, 86400, 0
	r.At, r.Timezone = strings.TrimSpace(at), strings.TrimSpace(tz)
	r.NextRunAt, r.UpdatedAt = next, s.now().UTC()
	changed, err := s.R.CompareAndSwap(ctx, "routines", id.String(), expected, r)
	if err != nil {
		return nil, err
	}
	if !changed {
		return nil, errs.Conflict("routine changed while updating; inspect its current state")
	}
	return r, nil
}
