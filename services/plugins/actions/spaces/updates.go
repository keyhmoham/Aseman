package spaces

import (
	"context"
	"github.com/aseman/aseman/pkg/errs"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/spaces/models/permission"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/spaces/models/turn"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// updatesOverlap re-reads a short window before the cursor so a row committed
// with a slightly earlier timestamp than a concurrent read is never skipped.
// Clients deduplicate by id (messages) and by id + updated_at (turns).
const updatesOverlap = 3 * time.Second

func updatesActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "spaces", Name: "updates", Summary: "Read a workspace's changes since a cursor (rooms, messages, work, live activity)", Handler: s.updates},
		helper.Action{Namespace: "spaces", Name: "live", Summary: "Follow a room's live activity: who is working and the answer being written", Handler: s.live},
	}
}

// liveHold is how long spaces.live waits for a change before answering anyway.
const liveHold = 20 * time.Second

// live follows one room while agents work in it: who is working, on what, and
// the answer being written so far. It is a long poll: given the `seq` of the
// last answer it returns as soon as something changes (or after liveHold), so
// a client sees an answer grow without asking several times a second. It reads
// memory only; messages and room work still come from spaces.updates.
func (s *Service) live(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space string `json:"space"`
		Room  string `json:"room"`
		Seq   uint64 `json:"seq,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	ids, err := parseIDs(in.Space, in.Room)
	if err != nil {
		return nil, errs.InvalidArgument("space and room are required")
	}
	if err := s.Can(ctx, ids[0], ids[1], req.Caller.ID, permission.RoomRead); err != nil {
		return nil, err
	}
	seq, changed := s.liveWait()
	if in.Seq != 0 && in.Seq == seq {
		timer := time.NewTimer(liveHold)
		defer timer.Stop()
		select {
		case <-changed:
		case <-timer.C:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		seq, _ = s.liveWait()
	}
	activity := []map[string]any{}
	for _, a := range s.RoomActivities(ids[1]) {
		activity = append(activity, map[string]any{"room_id": in.Room, "agent": a.Agent, "detail": a.Detail, "draft": a.Draft})
	}
	return helper.JSON(map[string]any{"seq": seq, "activity": activity})
}

// updates is the polling feed of a workspace: one call returns its rooms, the
// messages of every readable room and the room work (turns) changed since the
// cursor, plus which agent is working in each room right now. Without a cursor
// it returns the newest page, so the first call also seeds a client.
func (s *Service) updates(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string    `json:"space"`
		Since time.Time `json:"since,omitempty"`
		Limit int       `json:"limit,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, err
	}
	if err := s.Can(ctx, spID, identity.ID{}, req.Caller.ID, permission.SpaceView); err != nil {
		return nil, err
	}
	if in.Limit <= 0 || in.Limit > 500 {
		in.Limit = 200
	}
	now := time.Now().UTC()

	var rooms []space.Room
	if err := s.R.List(ctx, "rooms", database.Filter{Equal: map[string]any{"space_id": spID.String()}, OrderBy: "created_at", Asc: true}, &rooms); err != nil {
		return nil, err
	}
	readable := map[string]bool{}
	activity := []map[string]any{}
	visibleRooms := make([]space.Room, 0, len(rooms))
	for _, r := range rooms {
		if s.Can(ctx, spID, r.ID, req.Caller.ID, permission.RoomRead) != nil {
			continue
		}
		readable[r.ID.String()] = true
		visibleRooms = append(visibleRooms, r)
		for _, a := range s.RoomActivities(r.ID) {
			activity = append(activity, map[string]any{"room_id": r.ID.String(), "agent": a.Agent, "detail": a.Detail, "draft": a.Draft})
		}
	}

	msgFilter := database.Filter{Equal: map[string]any{"space_id": spID.String()}, OrderBy: "created_at", Asc: false, Limit: in.Limit + 1}
	turnFilter := database.Filter{Equal: map[string]any{"space_id": spID.String()}, OrderBy: "updated_at", Asc: false, Limit: in.Limit + 1}
	if !in.Since.IsZero() {
		from := in.Since.UTC().Add(-updatesOverlap)
		msgFilter.GreaterThan = map[string]any{"created_at": from}
		msgFilter.Asc = true
		turnFilter.GreaterThan = map[string]any{"updated_at": from}
		turnFilter.Asc = true
	}
	var msgs []message.Message
	if err := s.R.List(ctx, "messages", msgFilter, &msgs); err != nil {
		return nil, err
	}
	var turns []turn.Turn
	if err := s.R.List(ctx, "room_turns", turnFilter, &turns); err != nil {
		return nil, err
	}
	hasMore := len(msgs) > in.Limit || len(turns) > in.Limit
	cursor := now.Add(-updatesOverlap)
	if len(msgs) > in.Limit {
		msgs = msgs[:in.Limit]
		if msgFilter.Asc {
			cursor = msgs[len(msgs)-1].CreatedAt
		}
	}
	if len(turns) > in.Limit {
		turns = turns[:in.Limit]
		if turnFilter.Asc && turns[len(turns)-1].UpdatedAt.Before(cursor) {
			cursor = turns[len(turns)-1].UpdatedAt
		}
	}
	visible := msgs[:0]
	for _, m := range msgs {
		if readable[m.RoomID.String()] {
			visible = append(visible, m)
		}
	}
	work := make([]turn.Turn, 0, len(turns))
	for _, t := range turns {
		if readable[t.RoomID.String()] {
			work = append(work, t)
		}
	}
	return helper.JSON(map[string]any{
		"rooms":    visibleRooms,
		"messages": s.enrichMessages(ctx, visible),
		"turns":    work,
		"activity": activity,
		// How far the caller has read, on any device (zero when never).
		"seen_at":  s.SeenAt(ctx, req.Caller.ID, spID),
		"cursor":   cursor,
		"has_more": hasMore,
		"now":      now,
	})
}

// spaceActivity summarizes a workspace for a list card: its latest
// conversation message and whether room work is queued or running.
func (s *Service) spaceActivity(ctx context.Context, spaceID identity.ID, people *participants) map[string]any {
	out := map[string]any{"working": false}
	var recent []message.Message
	if err := s.R.List(ctx, "messages", database.Filter{Equal: map[string]any{"space_id": spaceID.String()}, OrderBy: "created_at", Asc: false, Limit: 10}, &recent); err == nil {
		for _, m := range recent {
			if m.Kind == message.KindLog || m.Kind == message.KindTool {
				continue
			}
			body := m.Body
			if r := []rune(body); len(r) > 200 {
				body = string(r[:200])
			}
			out["last_message"] = map[string]any{"id": m.ID.String(), "room_id": m.RoomID.String(), "body": body, "sender": people.get(ctx, m.SenderID), "created_at": m.CreatedAt}
			break
		}
	}
	if n, err := s.R.Count(ctx, "room_turns", database.Filter{Equal: map[string]any{"space_id": spaceID.String()}, In: map[string][]any{"status": {"queued", "running"}}}); err == nil {
		out["working"] = n > 0
	}
	return out
}
