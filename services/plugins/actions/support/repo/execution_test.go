package repo_test

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

func TestExecutionClaimIsExclusiveAndFencesPreviousOwner(t *testing.T) {
	ctx := context.Background()
	db := memory.New(logger.Global())
	for _, model := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, model); err != nil {
			t.Fatal(err)
		}
	}
	r := &repo.Repo{DB: db}
	claims := make(chan *repo.ExecutionLease, 16)
	var workers sync.WaitGroup
	for range 16 {
		workers.Add(1)
		go func() {
			defer workers.Done()
			lease, err := repo.ClaimExecution(ctx, r, 1, "workflow/run", time.Minute)
			if err != nil {
				if errs.CodeOf(err) != errs.CodeConflict {
					t.Errorf("claim failed: %v", err)
				}
				return
			}
			claims <- lease
		}()
	}
	workers.Wait()
	close(claims)
	if len(claims) != 1 {
		t.Fatalf("successful claims = %d, want 1", len(claims))
	}
	previous := <-claims
	if err := previous.Release(ctx, r); err != nil {
		t.Fatal(err)
	}
	current, err := repo.ClaimExecution(ctx, r, 1, "workflow/run", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if err := repo.CheckExecutionLease(repo.WithExecutionLease(ctx, previous), r); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("previous owner was not fenced: %v", err)
	}
	if err := previous.Renew(ctx, r, time.Minute); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("previous owner renewed a replaced lease: %v", err)
	}
	if err := repo.CheckExecutionLease(repo.WithExecutionLease(ctx, current), r); err != nil {
		t.Fatal(err)
	}
}

// Embedding the basic port intentionally hides optional capabilities while
// preserving all ordinary provider operations.
type basicProvider struct{ database.Database }

func TestMissingAtomicCapabilityFailsWithoutProviderPanic(t *testing.T) {
	db := memory.New(logger.Global())
	r := &repo.Repo{DB: basicProvider{Database: db}}
	if err := r.RequireAtomicUpdates(); errs.CodeOf(err) != errs.CodeUnavailable {
		t.Fatalf("capability error=%v", err)
	}
	if _, err := r.CompareAndSwap(context.Background(), "records", "id", nil, map[string]any{}); errs.CodeOf(err) != errs.CodeUnavailable {
		t.Fatalf("conditional update=%v", err)
	}
	if _, err := repo.ClaimExecution(context.Background(), r, 1, "run", time.Minute); errs.CodeOf(err) != errs.CodeUnavailable {
		t.Fatalf("claim=%v", err)
	}
	if err := r.DB.RegisterModel(context.Background(), database.Model{Name: "records", Table: "records", Fields: []database.Field{{Name: "id", Kind: database.KindString}}}); err != nil {
		t.Fatal(err)
	}
	if err := r.DB.Create(context.Background(), "records", "id", map[string]any{"id": "id"}); err != nil {
		t.Fatalf("basic CRUD disabled: %v", err)
	}
}
