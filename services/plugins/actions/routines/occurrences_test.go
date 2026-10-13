package routine

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	rt "github.com/tradera/tradera/plugins/actions/routines/models"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

func TestFailedCommandRetainsPartialOutputAndDoesNotBecomeDone(t *testing.T) {
	s, fake, ctx := harness(t)
	r := dueRoutine(t, s, ctx, "shell failure")
	fake.dispatchErr = errs.New(vmm.CodeToolExecutionFailed, "sandbox command exited with status 7")
	fake.dispatchResult = "exit=7\npartial diagnostic"
	if err := s.RunDue(ctx); err != nil {
		t.Fatal(err)
	}
	current, err := s.Get(ctx, r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if current.Status != rt.Failed || !strings.Contains(current.LastResult, fake.dispatchResult) {
		t.Fatalf("failed command was lost: %+v", current)
	}
	var runs []rt.Occurrence
	if err := s.R.List(ctx, "routine_runs", database.Filter{}, &runs); err != nil || len(runs) != 1 || runs[0].Status != "failed" || !strings.Contains(runs[0].Result, fake.dispatchResult) {
		t.Fatalf("incorrect occurrence evidence: %+v %v", runs, err)
	}
	current.Status = rt.Running
	if err := s.R.Update(ctx, "routines", current.ID, current); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Update(ctx, current.ID, "changed", "", "different", 0, 0); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("overwrote active occurrence: %v", err)
	}
}

type holdingSpaces struct {
	*fakeSpaces
	started chan struct{}
	release chan struct{}
}

func (f *holdingSpaces) AskBot(ctx context.Context, _ identity.ID, _ identity.ID, _ string, _ []vmm.FileAttachment, _ []vmm.ChatMessage) (string, error) {
	f.mu.Lock()
	f.asks++
	f.mu.Unlock()
	f.started <- struct{}{}
	select {
	case <-f.release:
		return "ok", nil
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

func dueRoutine(t *testing.T, s *Service, ctx context.Context, name string) *rt.Routine {
	t.Helper()
	workspace := identity.ID{Node: 1, Entity: 0x99}
	room := identity.ID{Node: 1, Entity: 0x98}
	owner := identity.ID{Node: 1, Entity: 1}
	record, err := s.Create(ctx, workspace, room, owner, name, rt.Delayed, owner.String(), "execute task", 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	record.NextRunAt = time.Now().UTC().Add(-time.Second)
	if err := s.R.Update(ctx, "routines", record.ID, record); err != nil {
		t.Fatal(err)
	}
	return record
}

func TestConcurrentSchedulerClaimsOneOccurrence(t *testing.T) {
	s, fake, ctx := harness(t)
	dueRoutine(t, s, ctx, "once")
	held := &holdingSpaces{fakeSpaces: fake, started: make(chan struct{}, 8), release: make(chan struct{})}
	s.Spaces = held
	other := NewService(s.K, s.R, s.L)
	other.Spaces = held
	var workers sync.WaitGroup
	workers.Add(2)
	for _, scheduler := range []*Service{s, other} {
		go func(scheduler *Service) {
			defer workers.Done()
			if err := scheduler.RunDue(ctx); err != nil {
				t.Error(err)
			}
		}(scheduler)
	}
	select {
	case <-held.started:
	case <-time.After(3 * time.Second):
		t.Fatal("occurrence did not dispatch")
	}
	close(held.release)
	workers.Wait()
	if fake.asks != 1 {
		t.Fatalf("duplicate dispatches = %d", fake.asks)
	}
	var occurrences []rt.Occurrence
	if err := s.R.List(ctx, "routine_runs", database.Filter{}, &occurrences); err != nil {
		t.Fatal(err)
	}
	if len(occurrences) != 1 || occurrences[0].Status != "done" {
		t.Fatalf("occurrences = %+v", occurrences)
	}
}

func TestRoutineClaimsAreAcquiredAfterWorkerSlot(t *testing.T) {
	s, fake, ctx := harness(t)
	for i := range 8 {
		dueRoutine(t, s, ctx, fmt.Sprint(i))
	}
	held := &holdingSpaces{fakeSpaces: fake, started: make(chan struct{}, 8), release: make(chan struct{})}
	s.Spaces = held
	returned := make(chan error, 1)
	go func() { returned <- s.RunDue(ctx) }()
	for range 4 {
		select {
		case <-held.started:
		case <-time.After(3 * time.Second):
			t.Fatal("worker wave did not start")
		}
	}
	var leases []repo.ExecutionLease
	if err := s.R.List(ctx, "execution_leases", database.Filter{}, &leases); err != nil {
		t.Fatal(err)
	}
	if len(leases) != 4 {
		t.Fatalf("queued routines hold %d leases, want 4 active leases", len(leases))
	}
	close(held.release)
	select {
	case err := <-returned:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("remaining worker wave did not finish")
	}
	if fake.asks != 8 {
		t.Fatalf("dispatched %d routines", fake.asks)
	}
}

func TestUnavailableOccurrenceRetriesSameSnapshot(t *testing.T) {
	s, fake, ctx := harness(t)
	record := dueRoutine(t, s, ctx, "retry")
	fake.dispatchErr = errs.New(errs.CodeUnavailable, "provider unavailable")
	if err := s.RunDue(ctx); err != nil {
		t.Fatal(err)
	}
	current, err := s.Get(ctx, record.ID)
	if err != nil {
		t.Fatal(err)
	}
	if current.Status != rt.Retrying || current.RetryCount != 1 || current.RetryAt == nil {
		t.Fatalf("retry state = %+v", current)
	}
	occurrenceID := current.ActiveRunID
	if err := s.RunDue(ctx); err != nil {
		t.Fatal(err)
	}
	if fake.asks != 1 {
		t.Fatal("retry ignored backoff")
	}
	before := time.Now().Add(-time.Second)
	current.RetryAt = &before
	if err := s.R.Update(ctx, "routines", current.ID, current); err != nil {
		t.Fatal(err)
	}
	fake.dispatchErr = nil
	if err := s.RunDue(ctx); err != nil {
		t.Fatal(err)
	}
	id, err := identity.Parse(occurrenceID)
	if err != nil {
		t.Fatal(err)
	}
	var occurrence rt.Occurrence
	if err := s.R.Get(ctx, "routine_runs", id, &occurrence); err != nil {
		t.Fatal(err)
	}
	if occurrence.Attempt != 2 || occurrence.Status != "done" || occurrence.Task != record.Task {
		t.Fatalf("retried occurrence = %+v", occurrence)
	}
}

func TestRecoveryCommitsOccurrenceWithoutRedispatch(t *testing.T) {
	s, fake, ctx := harness(t)
	record := dueRoutine(t, s, ctx, "recover")
	record.Status = rt.Running
	record.ActiveRunID = repo.ExecutionKey(record.ID.String() + "/" + record.NextRunAt.UTC().Format(time.RFC3339Nano))
	if err := s.R.Update(ctx, "routines", record.ID, record); err != nil {
		t.Fatal(err)
	}
	id, err := identity.Parse(record.ActiveRunID)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	occurrence := &rt.Occurrence{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, RoutineID: record.ID, SpaceID: record.SpaceID, RoomID: record.RoomID, CreatorID: record.CreatorID, Status: "done", Result: "committed result", Attempt: 1}
	if err := s.R.CreateID(ctx, "routine_runs", id, occurrence); err != nil {
		t.Fatal(err)
	}
	if err := s.RunDue(ctx); err != nil {
		t.Fatal(err)
	}
	current, err := s.Get(ctx, record.ID)
	if err != nil {
		t.Fatal(err)
	}
	if current.Status != rt.Done || current.LastResult != "committed result" || fake.asks != 0 {
		t.Fatalf("recovered routine = %+v, dispatches=%d", current, fake.asks)
	}
}
