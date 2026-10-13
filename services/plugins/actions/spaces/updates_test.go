package spaces

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
)

func callAs(t *testing.T, ctx context.Context, caller identity.ID, h func(context.Context, *api.ActionRequest) (*api.ActionResponse, error), body map[string]any, out any) {
	t.Helper()
	raw, _ := json.Marshal(body)
	resp, err := h(ctx, &api.ActionRequest{Caller: api.Caller{ID: caller, Kind: "user"}, Body: raw})
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(resp.Body, out); err != nil {
		t.Fatal(err)
	}
}

func seedMessages(t *testing.T, s *Service, ctx context.Context, sp, room, sender identity.ID, base time.Time, n int) []identity.ID {
	t.Helper()
	ids := make([]identity.ID, 0, n)
	for i := 0; i < n; i++ {
		id, err := identity.New(s.K.NodeID())
		if err != nil {
			t.Fatal(err)
		}
		at := base.Add(time.Duration(i) * time.Minute)
		m := &message.Message{Entity: entity.Entity{ID: id, CreatedAt: at, UpdatedAt: at}, SpaceID: sp, RoomID: room, SenderID: sender, Body: "m"}
		if err := s.R.CreateID(ctx, "messages", id, m); err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	return ids
}

type listedMessages struct {
	Messages []struct {
		ID     string         `json:"id"`
		Sender map[string]any `json:"sender"`
	} `json:"messages"`
	HasMore bool `json:"has_more"`
}

func TestMessageListCursorsAndSender(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	now := time.Now().UTC()
	if err := s.R.CreateID(ctx, "accounts", owner, &account.Account{Entity: entity.Entity{ID: owner, CreatedAt: now, UpdatedAt: now}, Kind: account.KindUser, Handle: "alice", Status: account.StatusActive}); err != nil {
		t.Fatal(err)
	}
	sp, err := s.CreateSpace(ctx, owner, "cursor test", "")
	if err != nil {
		t.Fatal(err)
	}
	room, err := s.generalRoom(ctx, sp.ID)
	if err != nil {
		t.Fatal(err)
	}
	base := now.Add(-time.Hour)
	ids := seedMessages(t, s, ctx, sp.ID, room.ID, owner, base, 5)
	list := (&msgListAction{s: s}).Handle

	var newest listedMessages
	callAs(t, ctx, owner, list, map[string]any{"space": sp.ID.String(), "room": room.ID.String(), "limit": 2}, &newest)
	if len(newest.Messages) != 2 || newest.Messages[0].ID != ids[4].String() || newest.Messages[1].ID != ids[3].String() || !newest.HasMore {
		t.Fatalf("newest page wrong: %+v", newest)
	}
	if newest.Messages[0].Sender["handle"] != "alice" || newest.Messages[0].Sender["kind"] != "user" {
		t.Fatalf("sender not enriched: %+v", newest.Messages[0].Sender)
	}

	var older listedMessages
	callAs(t, ctx, owner, list, map[string]any{"space": sp.ID.String(), "room": room.ID.String(), "limit": 2, "before": base.Add(3 * time.Minute)}, &older)
	if len(older.Messages) != 2 || older.Messages[0].ID != ids[2].String() || older.Messages[1].ID != ids[1].String() || !older.HasMore {
		t.Fatalf("before page wrong: %+v", older)
	}

	var newer listedMessages
	callAs(t, ctx, owner, list, map[string]any{"space": sp.ID.String(), "room": room.ID.String(), "limit": 10, "after": base.Add(2 * time.Minute)}, &newer)
	if len(newer.Messages) != 2 || newer.Messages[0].ID != ids[4].String() || newer.Messages[1].ID != ids[3].String() || newer.HasMore {
		t.Fatalf("after page wrong: %+v", newer)
	}
}

func TestUpdatesFeedSinceCursor(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "updates test", "")
	if err != nil {
		t.Fatal(err)
	}
	room, err := s.generalRoom(ctx, sp.ID)
	if err != nil {
		t.Fatal(err)
	}
	old := seedMessages(t, s, ctx, sp.ID, room.ID, owner, time.Now().UTC().Add(-time.Hour), 2)

	var first struct {
		Rooms    []map[string]any `json:"rooms"`
		Messages []struct {
			ID string `json:"id"`
		} `json:"messages"`
		Cursor time.Time `json:"cursor"`
	}
	callAs(t, ctx, owner, s.updates, map[string]any{"space": sp.ID.String()}, &first)
	if len(first.Rooms) == 0 || len(first.Messages) != 2 || first.Cursor.IsZero() {
		t.Fatalf("initial read wrong: %+v", first)
	}

	fresh := seedMessages(t, s, ctx, sp.ID, room.ID, owner, time.Now().UTC().Add(time.Second), 1)
	var next struct {
		Messages []struct {
			ID string `json:"id"`
		} `json:"messages"`
	}
	callAs(t, ctx, owner, s.updates, map[string]any{"space": sp.ID.String(), "since": first.Cursor}, &next)
	if len(next.Messages) != 1 || next.Messages[0].ID != fresh[0].String() {
		t.Fatalf("since cursor must return only the new message (old %v): %+v", old, next)
	}

	stranger := idFromHex(t, "00000000000000010000000000000099")
	raw, _ := json.Marshal(map[string]any{"space": sp.ID.String()})
	if _, err := s.updates(ctx, &api.ActionRequest{Caller: api.Caller{ID: stranger, Kind: "user"}, Body: raw}); err == nil {
		t.Fatal("a non-member must not read a private workspace's updates")
	}
}
