package memory

import (
	"context"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

type testRec struct {
	entity.Entity
	Name   string      `db:"name" json:"name"`
	Owner  identity.ID `db:"owner_id" json:"owner_id"`
	Count  int64       `db:"count" json:"count"`
	Active bool        `db:"active" json:"active"`
	When   *time.Time  `db:"when" json:"when,omitempty"`
}

var testModel = database.Model{
	Name:  "testrecs",
	Table: "testrecs",
	Fields: []database.Field{
		{Name: "id", Kind: database.KindString},
		{Name: "name", Kind: database.KindString},
		{Name: "owner_id", Kind: database.KindString},
		{Name: "count", Kind: database.KindInt64},
		{Name: "active", Kind: database.KindBool},
		{Name: "when", Kind: database.KindTime},
		{Name: "created_at", Kind: database.KindTime},
		{Name: "updated_at", Kind: database.KindTime},
	},
}

func setup(t *testing.T) (database.Database, context.Context) {
	t.Helper()
	ad := New(logger.Global())
	ctx := context.Background()
	if err := ad.RegisterModel(ctx, testModel); err != nil {
		t.Fatal(err)
	}
	return ad, ctx
}

func TestRoundTripEmbeddedEntity(t *testing.T) {
	ad, ctx := setup(t)
	id, _ := identity.New(7)
	now := time.Now().UTC()
	rec := &testRec{
		Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		Name:   "alpha", Owner: id, Count: 3, Active: true, When: &now,
	}
	if err := ad.Create(ctx, "testrecs", id.String(), rec); err != nil {
		t.Fatal(err)
	}
	out := &testRec{}
	if err := ad.Get(ctx, "testrecs", id.String(), out); err != nil {
		t.Fatal(err)
	}
	if out.ID != id {
		t.Fatalf("embedded id not restored: %v != %v", out.ID, id)
	}
	if out.Name != "alpha" || out.Count != 3 || !out.Active {
		t.Fatalf("fields not restored: %+v", out)
	}
	if out.Owner != id {
		t.Fatalf("owner not restored: %v", out.Owner)
	}
	if out.When == nil || !out.When.Equal(now) {
		t.Fatalf("pointer time not restored: %v", out.When)
	}
	if out.CreatedAt.IsZero() {
		t.Fatal("created_at not restored")
	}
}

func TestFilterAndPaging(t *testing.T) {
	ad, ctx := setup(t)
	for i := 0; i < 5; i++ {
		id, _ := identity.New(1)
		r := &testRec{Entity: entity.Entity{ID: id}, Name: "n" + string(rune('a'+i)), Count: int64(i), Active: i%2 == 0}
		if err := ad.Create(ctx, "testrecs", id.String(), r); err != nil {
			t.Fatal(err)
		}
	}
	var out []testRec
	if err := ad.List(ctx, "testrecs", database.Filter{
		Equal: map[string]any{"active": true}, OrderBy: "count", Asc: true, Limit: 2,
	}, &out); err != nil {
		t.Fatal(err)
	}
	if len(out) != 2 || out[0].Count != 0 || out[1].Count != 2 {
		t.Fatalf("filter/paging wrong: %+v", out)
	}
	n, err := ad.Count(ctx, "testrecs", database.Filter{Equal: map[string]any{"active": true}})
	if err != nil || n != 3 {
		t.Fatalf("count = %d err=%v", n, err)
	}
}

func TestOrderByTime(t *testing.T) {
	ad, ctx := setup(t)
	base := time.Now().UTC()
	for i := 0; i < 25; i++ {
		id, _ := identity.New(1)
		r := &testRec{Entity: entity.Entity{ID: id, CreatedAt: base.Add(time.Duration(i) * time.Minute)}}
		if err := ad.Create(ctx, "testrecs", id.String(), r); err != nil {
			t.Fatal(err)
		}
	}
	var out []testRec
	if err := ad.List(ctx, "testrecs", database.Filter{OrderBy: "created_at", Asc: false, Limit: 30}, &out); err != nil {
		t.Fatal(err)
	}
	if len(out) != 25 {
		t.Fatalf("expected 25 records, got %d", len(out))
	}
	for i := 1; i < len(out); i++ {
		if out[i].CreatedAt.After(out[i-1].CreatedAt) {
			t.Fatalf("not newest-first at index %d: %v after %v", i, out[i].CreatedAt, out[i-1].CreatedAt)
		}
	}
	// The newest record must be first (this is what feeds rely on).
	if !out[0].CreatedAt.Equal(base.Add(24 * time.Minute)) {
		t.Fatalf("newest record not first: got %v", out[0].CreatedAt)
	}
}

func TestNotExist(t *testing.T) {
	ad, ctx := setup(t)
	id, _ := identity.New(1)
	out := &testRec{}
	if err := ad.Get(ctx, "testrecs", id.String(), out); err == nil {
		t.Fatal("expected not found")
	}
}

func TestCanonicalModelsRoundTrip(t *testing.T) {
	ad := New(logger.Global())
	ctx := context.Background()
	for _, m := range dbmodel.Models() {
		if err := ad.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	id, _ := identity.New(3)
	sp := space.New(id, id, "test space")
	if err := ad.Create(ctx, "spaces", id.String(), sp); err != nil {
		t.Fatal(err)
	}
	out := &space.Space{}
	if err := ad.Get(ctx, "spaces", id.String(), out); err != nil {
		t.Fatal(err)
	}
	if out.ID != id || out.OwnerID != id || out.Name != "test space" {
		t.Fatalf("space not restored: %+v", out)
	}
}

func TestConditionalReplacementPreservesPortSemantics(t *testing.T) {
	db, ctx := setup(t)
	atomic := db.(database.AtomicUpdater)
	id := identity.ID{Node: 1, Entity: 1}.String()
	replacement := map[string]any{"id": "different-id", "name": "new", "when": nil}
	if err := db.Create(ctx, "testrecs", id, map[string]any{"id": id, "name": "old", "when": nil}); err != nil {
		t.Fatal(err)
	}
	if changed, err := atomic.CompareAndSwap(ctx, "testrecs", id, map[string]any{"name": "stale"}, replacement); changed || err != nil {
		t.Fatalf("mismatch=%v %v", changed, err)
	}
	if changed, err := atomic.CompareAndSwap(ctx, "testrecs", id, map[string]any{"when": nil, "name": "old"}, replacement); !changed || err != nil {
		t.Fatalf("null match=%v %v", changed, err)
	}
	row := map[string]any{}
	if err := db.Get(ctx, "testrecs", id, &row); err != nil {
		t.Fatal(err)
	}
	if row["id"] != id || row["name"] != "new" {
		t.Fatalf("replacement=%v", row)
	}
	if changed, err := atomic.CompareAndSwap(ctx, "testrecs", "absent", map[string]any{"name": "old"}, replacement); changed || err != nil {
		t.Fatalf("missing=%v %v", changed, err)
	}
	if _, err := atomic.CompareAndSwap(ctx, "testrecs", "absent", map[string]any{"unknown": "x"}, replacement); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("unknown field=%v", err)
	}
}

var txIDs = map[string]string{
	"a": "0000000000000001000000000000000a", "b": "0000000000000001000000000000000b",
	"x": "0000000000000001000000000000000c", "y": "0000000000000001000000000000000d", "z": "0000000000000001000000000000000e",
}

func txHarness(t *testing.T) (*Adapter, context.Context) {
	t.Helper()
	a := New(logger.Global())
	ctx := context.Background()
	if err := a.RegisterModel(ctx, testModel); err != nil {
		t.Fatal(err)
	}
	return a, ctx
}

func TestTransactionReadsAndWritesWithoutDeadlock(t *testing.T) {
	a, ctx := txHarness(t)
	if err := a.Create(ctx, "testrecs", txIDs["a"], &testRec{Name: "a", Count: 1}); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		done <- a.Transaction(ctx, func(ctx context.Context, tx database.Tx) error {
			var r testRec
			if err := tx.Get(ctx, "testrecs", txIDs["a"], &r); err != nil {
				return err
			}
			r.Count++
			if err := tx.Update(ctx, "testrecs", txIDs["a"], &r); err != nil {
				return err
			}
			return tx.Create(ctx, "testrecs", txIDs["b"], &testRec{Name: "b"})
		})
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("transaction deadlocked")
	}
	var r testRec
	if err := a.Get(ctx, "testrecs", txIDs["a"], &r); err != nil || r.Count != 2 {
		t.Fatalf("update not applied: %+v %v", r, err)
	}
}

func TestFailedTransactionRollsBack(t *testing.T) {
	a, ctx := txHarness(t)
	if err := a.Create(ctx, "testrecs", txIDs["a"], &testRec{Name: "a", Count: 1}); err != nil {
		t.Fatal(err)
	}
	err := a.Transaction(ctx, func(ctx context.Context, tx database.Tx) error {
		if err := tx.Update(ctx, "testrecs", txIDs["a"], &testRec{Name: "a", Count: 9}); err != nil {
			return err
		}
		if err := tx.Create(ctx, "testrecs", txIDs["b"], &testRec{Name: "b"}); err != nil {
			return err
		}
		if err := tx.Delete(ctx, "testrecs", txIDs["a"]); err != nil {
			return err
		}
		return errs.Conflict("abort")
	})
	if errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("expected the transaction error, got %v", err)
	}
	var r testRec
	if err := a.Get(ctx, "testrecs", txIDs["a"], &r); err != nil || r.Count != 1 {
		t.Fatalf("a must be restored to its original value: %+v %v", r, err)
	}
	if err := a.Get(ctx, "testrecs", txIDs["b"], &r); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("b must not exist after rollback: %v", err)
	}
}

func TestRangeFilterComparesTimes(t *testing.T) {
	a, ctx := txHarness(t)
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	for i, name := range []string{"x", "y", "z"} {
		at := base.Add(time.Duration(i) * time.Hour)
		if err := a.Create(ctx, "testrecs", txIDs[name], &testRec{Entity: entity.Entity{CreatedAt: at}, Name: name}); err != nil {
			t.Fatal(err)
		}
	}
	var rows []testRec
	if err := a.List(ctx, "testrecs", database.Filter{GreaterThan: map[string]any{"created_at": base}, LessThan: map[string]any{"created_at": base.Add(2 * time.Hour)}}, &rows); err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Name != "y" {
		t.Fatalf("time range filter wrong: %+v", rows)
	}
}
