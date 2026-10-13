package usages

import (
	"context"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/actions/usage/models"
	"github.com/tradera/tradera/plugins/adapters/database/memory"
	dbmodel "github.com/tradera/tradera/plugins/testutil"
)

func usageHarness(t *testing.T) (*Service, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := context.Background()
	for _, m := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global()})
	r := &repo.Repo{DB: db}
	s := NewService(k, r, logger.Global())
	return s, ctx
}

func TestRecordSkipsZeroUsage(t *testing.T) {
	s, ctx := usageHarness(t)
	space := mustID(t, "00000000000000010000000000000001")
	if err := s.Record(ctx, &usage.Usage{SpaceID: space, TokensIn: 0, TokensOut: 0}); err != nil {
		t.Fatal(err)
	}
	rows, err := s.List(ctx, space, identity.ID{}, identity.ID{}, 10, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Fatalf("expected no zero-usage rows, got %d", len(rows))
	}
}

func TestRecordListAndSummary(t *testing.T) {
	s, ctx := usageHarness(t)
	space := mustID(t, "00000000000000010000000000000001")
	room := mustID(t, "00000000000000010000000000000002")
	actor := mustID(t, "00000000000000010000000000000003")
	bot := mustID(t, "00000000000000010000000000000004")

	for i := 0; i < 2; i++ {
		u := &usage.Usage{SpaceID: space, RoomID: room, BotID: bot,
			BotName: "AlphaBot", ActorID: actor, RequestID: "req-1", Kind: usage.KindAsk,
			TokensIn: 100, TokensOut: 20, Cost: 3}
		u.Entity = entity.Entity{CreatedAt: time.Now().UTC()}
		if err := s.Record(ctx, u); err != nil {
			t.Fatal(err)
		}
	}
	room2 := mustID(t, "00000000000000010000000000000005")
	bot2 := mustID(t, "00000000000000010000000000000006")
	if err := s.Record(ctx, &usage.Usage{SpaceID: space, RoomID: room2, BotID: bot2,
		BotName: "SignalBot", ActorID: actor, RequestID: "req-2", Kind: usage.KindMention,
		TokensIn: 40, TokensOut: 10, Cost: 1}); err != nil {
		t.Fatal(err)
	}

	rows, err := s.List(ctx, space, identity.ID{}, identity.ID{}, 10, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 3 {
		t.Fatalf("expected 3 usage rows, got %d", len(rows))
	}

	sum, err := s.Summary(ctx, space, 100)
	if err != nil {
		t.Fatal(err)
	}
	if sum["total_in"].(int64) != 240 || sum["total_out"].(int64) != 50 {
		t.Fatalf("totals = in %v out %v, want 240/50", sum["total_in"], sum["total_out"])
	}
	if sum["total_cost"].(int64) != 7 {
		t.Fatalf("total_cost = %v, want 7", sum["total_cost"])
	}
	if rooms := sum["rooms"].([]*rollup); len(rooms) != 2 {
		t.Fatalf("expected 2 room rollups, got %d", len(rooms))
	}
	if agents := sum["agents"].([]*rollup); len(agents) != 2 {
		t.Fatalf("expected 2 agent rollups, got %d", len(agents))
	}
}

func TestUsageDeltaSummary(t *testing.T) {
	d := usage.Delta{TokensIn: 1234, TokensOut: 56, Cost: 5}
	if s := d.Summary(); s == "" || len(s) < 10 {
		t.Fatalf("summary too short: %q", s)
	}
	if !((usage.Delta{}).Zero()) {
		t.Fatal("zero delta should report zero")
	}
}

func mustID(t *testing.T, s string) identity.ID {
	t.Helper()
	id, err := identity.Parse(s)
	if err != nil {
		t.Fatal(err)
	}
	return id
}
