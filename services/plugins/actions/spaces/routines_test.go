package spaces

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/routines"
	rt "github.com/aseman/aseman/plugins/actions/routines/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

// TestAgentRoutineToolDefaultsToContextRoom guards the bug where routines an
// agent schedules in a room were stored under the zero room (room_id 0000…00)
// and thus never appeared in the room's routines panel. The routine tools must
// default to the room the request is running in.
func TestAgentRoutineToolDefaultsToContextRoom(t *testing.T) {
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
	s.Routines = routine.NewService(k, r, logger.Global())

	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "test space", "")
	if err != nil {
		t.Fatal(err)
	}
	// A second room (the one the "agent" is working in) alongside general.
	room2 := idFromHex(t, "00000000000000010000000000000009")
	now := time.Now().UTC()
	if err := s.R.CreateID(ctx, "rooms", room2, &space.Room{
		Entity:  entity.Entity{ID: room2, CreatedAt: now, UpdatedAt: now},
		SpaceID: sp.ID, Name: "design", MetadataID: room2,
	}); err != nil {
		t.Fatal(err)
	}

	// The agent calls routine_create with NO room argument; only the request
	// context carries the room it is working in.
	roomCtx := vmm.WithRoom(helper.WithActor(ctx, owner), room2.String())
	if _, err := s.handleRoutineTool(roomCtx, sp.ID, identity.ID{}, "routine_create",
		`{"name":"scan","type":"periodic","task":"market scan","interval_sec":600}`); err != nil {
		t.Fatal(err)
	}

	// The same room's list (as the agent would query it) sees the routine.
	lst, err := s.handleRoutineTool(roomCtx, sp.ID, identity.ID{}, "routine_list", `{}`)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(lst, "scan") {
		t.Fatalf("routine created in the context room should list there, got: %q", lst)
	}

	// The general room must NOT see it (it was scheduled in room2).
	gr, err := s.generalRoom(ctx, sp.ID)
	if err != nil {
		t.Fatal(err)
	}
	lstGeneral, err := s.handleRoutineTool(helper.WithActor(ctx, owner), sp.ID, gr.ID, "routine_list", `{}`)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(lstGeneral, "scan") {
		t.Fatalf("routine must not leak into the general room, got: %q", lstGeneral)
	}
}

func TestRoutineToolReturnsVerifiableScheduleAndRejectsUnknownType(t *testing.T) {
	s, internal := fileToolHarness(t)
	s.Routines = routine.NewService(s.K, s.R, logger.Global())
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(internal, owner, "scheduled work", "")
	if err != nil {
		t.Fatal(err)
	}
	room := testWorkerRoom(t, s, internal, sp.ID, "general")
	ctx := vmm.WithRoom(helper.WithActor(context.Background(), owner), room.String())
	if _, err := s.handleRoutineTool(ctx, sp.ID, room, "routine_create", `{"type":"perodic","task":"refresh"}`); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("unknown type became a delayed job: %v", err)
	}
	created, err := s.handleRoutineTool(ctx, sp.ID, room, "routine_create", `{"name":"news","type":"periodic","task":"refresh","interval_sec":600}`)
	if err != nil {
		t.Fatal(err)
	}
	var record rt.Routine
	if err := json.Unmarshal([]byte(created), &record); err != nil {
		t.Fatal(err)
	}
	if record.ID.IsZero() || record.RoomID != room || record.CreatorID != owner || record.IntervalSec != 600 || record.Type != rt.Periodic || record.Task != "refresh" || record.Status != rt.Active {
		t.Fatalf("incomplete receipt: %+v", record)
	}
	listed, err := s.handleRoutineTool(ctx, sp.ID, room, "routine_list", `{}`)
	if err != nil {
		t.Fatal(err)
	}
	var records []rt.Routine
	if err := json.Unmarshal([]byte(listed), &records); err != nil || len(records) != 1 || records[0].ID != record.ID || records[0].IntervalSec != 600 {
		t.Fatalf("list does not verify saved schedule: %s %v", listed, err)
	}
	updated, err := s.handleRoutineTool(ctx, sp.ID, room, "routine_update", `{"id":"`+record.ID.String()+`","task":"node scripts/update-news.mjs"}`)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(updated), &record); err != nil || record.IntervalSec != 600 || record.Task != "node scripts/update-news.mjs" {
		t.Fatalf("update changed unrelated schedule fields: %s %v", updated, err)
	}
	inspected, err := s.handleRoutineTool(ctx, sp.ID, room, "routine_get", `{"id":"`+record.ID.String()+`"}`)
	if err != nil || inspected != updated {
		t.Fatalf("get did not return persisted update: %s %v", inspected, err)
	}
	otherRoom := testWorkerRoom(t, s, internal, sp.ID, "other")
	for _, tool := range []string{"routine_get", "routine_update", "routine_delete"} {
		if _, err := s.handleRoutineTool(ctx, sp.ID, otherRoom, tool, `{"id":"`+record.ID.String()+`","task":"different"}`); errs.CodeOf(err) != errs.CodePermission {
			t.Fatalf("%s crossed room boundary: %v", tool, err)
		}
	}
}
