package spaces

// Room threads: a room's conversation can be split into threads, each with
// its own history and its own agent context. People switch between a room's
// threads in the chat; an app that asks an agent gets a temporary thread of
// its own for that one ask, deleted as soon as the agent is done.
//
// A thread is stored as a room whose ParentID names the room it belongs to.
// Everything keyed by room — its messages, each agent's conversation in the
// runtime, what agents catch up on and their memory sessions — is therefore
// the thread's own, with no change to any of it. What belongs to the room as
// a whole resolves a thread to its room (mainRoom): room grants (Can), the
// desk, notifications and the room listings, which never show threads. The
// room itself is its main thread.

import (
	"context"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/spaces/models/permission"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/models/metadata"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

const (
	// newThreadTitle names a thread until its first message names it.
	newThreadTitle = "New thread"
	// tempThreadTTL is how long a temporary thread may outlive the ask that
	// opened it (a crash between the ask and its cleanup) before the sweep
	// deletes it.
	tempThreadTTL = time.Hour
	// maxThreadsPerRoom bounds a room's open threads.
	maxThreadsPerRoom = 200
)

// roomParent returns the room [roomID] is a thread of, or the zero id when it
// is a room (or unknown). Parents never change, so answers are cached.
func (s *Service) roomParent(ctx context.Context, roomID identity.ID) identity.ID {
	if roomID.IsZero() {
		return identity.ID{}
	}
	if v, ok := s.threadRooms.Load(roomID); ok {
		return v.(identity.ID)
	}
	room, err := s.GetRoom(ctx, roomID)
	if err != nil {
		return identity.ID{}
	}
	parent := identity.ID{}
	if room.IsThread() {
		parent, _ = identity.Parse(room.ParentID)
	}
	s.threadRooms.Store(roomID, parent)
	return parent
}

// mainRoom resolves a thread to the room it belongs to; a room is its own.
func (s *Service) mainRoom(ctx context.Context, roomID identity.ID) identity.ID {
	if parent := s.roomParent(ctx, roomID); !parent.IsZero() {
		return parent
	}
	return roomID
}

// visibleRooms drops threads from a list of rooms: listings show rooms only.
func visibleRooms(rooms []space.Room) []space.Room {
	out := rooms[:0]
	for _, r := range rooms {
		if !r.IsThread() {
			out = append(out, r)
		}
	}
	return out
}

// CreateThread opens a thread in a room of a space. A temporary thread is
// for one piece of work and is deleted with DeleteThread when it is done.
func (s *Service) CreateThread(ctx context.Context, spaceID, roomID, creator identity.ID, title string, temporary bool) (*space.Room, error) {
	roomID = s.mainRoom(ctx, roomID)
	room, err := s.GetRoom(ctx, roomID)
	if err != nil {
		return nil, err
	}
	if room.SpaceID != spaceID {
		return nil, errs.NotFound("room not found in this space")
	}
	if !temporary {
		if n, err := s.R.Count(ctx, "rooms", database.Filter{Equal: map[string]any{"parent_id": roomID.String(), "temporary": false}}); err == nil && n >= maxThreadsPerRoom {
			return nil, errs.Conflict("this room has too many threads; delete some first")
		}
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	title = clipTitle(title)
	if title == "" {
		title = newThreadTitle
	}
	now := time.Now().UTC()
	thread := &space.Room{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		SpaceID: spaceID, Name: title, MetadataID: id, ParentID: roomID.String(), Temporary: temporary}
	if !creator.IsZero() {
		thread.CreatorID = creator.String()
	}
	if err := s.R.CreateID(ctx, "rooms", id, thread); err != nil {
		return nil, err
	}
	s.threadRooms.Store(id, roomID)
	if !temporary {
		meta := &metadata.Record{Owner: id.String(), Tree: metadata.Tree{"name": title},
			PublicPaths: []string{}, Version: 1, UpdatedAt: now}
		_ = s.R.CreateID(ctx, "metadatas", id, meta)
	}
	return thread, nil
}

// DeleteThread deletes a thread with its messages and every agent's
// conversation of it. Deleting a room that is not a thread is refused.
func (s *Service) DeleteThread(ctx context.Context, thread *space.Room) error {
	if !thread.IsThread() {
		return errs.InvalidArgument("not a thread; the main thread is the room itself")
	}
	ctx = context.WithoutCancel(ctx)
	for range 1000 { // bounded: 200 messages a page
		var msgs []message.Message
		if err := s.R.List(ctx, "messages", database.Filter{
			Equal: map[string]any{"room_id": thread.ID.String()}, Limit: 200,
		}, &msgs); err != nil {
			return err
		}
		if len(msgs) == 0 {
			break
		}
		for i := range msgs {
			s.deleteMessageEdits(ctx, msgs[i].ID)
			if err := s.R.Delete(ctx, "messages", msgs[i].ID); err != nil {
				return err
			}
		}
	}
	if s.K != nil {
		if f, ok := s.K.VMMFor(vmm.TypeDeepAgents).(vmm.RoomForgetter); ok && f != nil {
			if err := f.ForgetRoom(ctx, thread.SpaceID.String(), thread.ID.String()); err != nil && s.L != nil {
				s.L.Warn("agents' thread conversations not forgotten", "thread", thread.ID.String(), "error", err)
			}
		}
	}
	_ = s.R.Delete(ctx, "metadatas", thread.ID)
	if err := s.R.Delete(ctx, "rooms", thread.ID); err != nil && errs.CodeOf(err) != errs.CodeNotFound {
		return err
	}
	return nil
}

// WithTempThread runs [work] in a temporary thread of a room, opened for it
// and deleted when it returns: an app asking an agent gets a fresh
// conversation every time, and leaves nothing behind.
func (s *Service) WithTempThread(ctx context.Context, spaceID, roomID, creator identity.ID, title string, work func(threadID identity.ID) error) error {
	thread, err := s.CreateThread(ctx, spaceID, roomID, creator, title, true)
	if err != nil {
		return err
	}
	defer func() {
		if err := s.DeleteThread(ctx, thread); err != nil && s.L != nil {
			s.L.Warn("temporary thread not deleted; the sweep will", "thread", thread.ID.String(), "error", err)
		}
	}()
	return work(thread.ID)
}

// RoomThreads lists a room's threads, most recently active first.
func (s *Service) RoomThreads(ctx context.Context, roomID identity.ID, temporary bool) ([]space.Room, error) {
	var threads []space.Room
	if err := s.R.List(ctx, "rooms", database.Filter{
		Equal: map[string]any{"parent_id": roomID.String()}, OrderBy: "updated_at", Asc: false, Limit: maxThreadsPerRoom * 2,
	}, &threads); err != nil {
		return nil, err
	}
	out := threads[:0]
	for _, t := range threads {
		if t.Temporary == temporary {
			out = append(out, t)
		}
	}
	return out, nil
}

// touchThread records activity in a thread: the first message names a
// thread that has no name of its own yet, and every message moves it to the
// top of the room's threads.
func (s *Service) touchThread(ctx context.Context, roomID identity.ID, body string) {
	if s.roomParent(ctx, roomID).IsZero() {
		return
	}
	thread, err := s.GetRoom(ctx, roomID)
	if err != nil || thread.Temporary {
		return
	}
	if thread.Name == newThreadTitle {
		if t := clipTitle(body); t != "" {
			thread.Name = t
		}
	}
	thread.UpdatedAt = time.Now().UTC()
	_ = s.R.Update(ctx, "rooms", thread.ID, thread)
}

// sweepTempThreads deletes temporary threads left behind (the node stopped
// between an ask and its cleanup), now and every so often.
func (s *Service) sweepTempThreads(ctx context.Context) {
	sweep := func() {
		var threads []space.Room
		if err := s.R.List(ctx, "rooms", database.Filter{
			Equal: map[string]any{"temporary": true}, LessThan: map[string]any{"created_at": time.Now().UTC().Add(-tempThreadTTL)}, Limit: 500,
		}, &threads); err != nil {
			return
		}
		for i := range threads {
			_ = s.DeleteThread(ctx, &threads[i])
		}
	}
	sweep()
	tick := time.NewTicker(tempThreadTTL / 4)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			sweep()
		}
	}
}

// clipTitle makes a one-line thread title of at most 60 characters.
func clipTitle(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if utf8.RuneCountInString(s) <= 60 {
		return s
	}
	r := []rune(s)
	return strings.TrimSpace(string(r[:59])) + "…"
}

// ── actions ─────────────────────────────────────────────────────────────────

func threadActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "spaces", Name: "thread_list", Summary: "List a room's conversation threads", Handler: s.threadList},
		helper.Action{Namespace: "spaces", Name: "thread_create", Summary: "Open a new conversation thread in a room", Handler: s.threadCreate},
		helper.Action{Namespace: "spaces", Name: "thread_rename", Summary: "Rename a conversation thread", Handler: s.threadRename},
		helper.Action{Namespace: "spaces", Name: "thread_delete", Summary: "Delete a conversation thread with its messages", Handler: s.threadDelete},
	}
}

// threadView is a thread as clients see it.
func (s *Service) threadView(ctx context.Context, t *space.Room) map[string]any {
	out := map[string]any{
		"id": t.ID.String(), "room_id": t.ParentID, "space_id": t.SpaceID.String(), "title": t.Name,
		"created_at": t.CreatedAt, "updated_at": t.UpdatedAt, "temporary": t.Temporary,
	}
	if t.CreatorID != "" {
		out["creator_id"] = t.CreatorID
	}
	if last := s.lastRoomMessage(ctx, t.ID); last != nil {
		out["last"] = map[string]any{"body": clipTrace(last.Body, 160), "sender_id": last.SenderID.String(), "created_at": last.CreatedAt}
	}
	return out
}

// threadRoom loads a thread for an action of [caller] needing [perm] on its room.
func (s *Service) threadRoom(ctx context.Context, caller identity.ID, raw, perm string) (*space.Room, error) {
	id, err := identity.Parse(raw)
	if err != nil {
		return nil, errs.InvalidArgument("invalid thread id")
	}
	thread, err := s.GetRoom(ctx, id)
	if err != nil {
		return nil, err
	}
	if !thread.IsThread() {
		return nil, errs.InvalidArgument("not a thread; the main thread is the room itself")
	}
	parent, _ := identity.Parse(thread.ParentID)
	if thread.CreatorID == caller.String() {
		perm = permission.RoomRead // what you opened is yours to rename or delete
	}
	if err := s.Can(ctx, thread.SpaceID, parent, caller, perm); err != nil {
		return nil, err
	}
	return thread, nil
}

func (s *Service) threadList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Room  string `json:"room"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	roomID, err := identity.Parse(in.Room)
	if err != nil {
		return nil, errs.InvalidArgument("invalid room id")
	}
	roomID = s.mainRoom(ctx, roomID)
	if err := s.Can(ctx, spID, roomID, req.Caller.ID, permission.RoomRead); err != nil {
		return nil, err
	}
	threads, err := s.RoomThreads(ctx, roomID, false)
	if err != nil {
		return nil, err
	}
	views := make([]map[string]any, 0, len(threads))
	for i := range threads {
		views = append(views, s.threadView(ctx, &threads[i]))
	}
	// Most recent activity first: a thread's last message, else its own time.
	active := func(v map[string]any) time.Time {
		if last, ok := v["last"].(map[string]any); ok {
			if t, ok := last["created_at"].(time.Time); ok {
				return t
			}
		}
		t, _ := v["updated_at"].(time.Time)
		return t
	}
	sort.SliceStable(views, func(i, j int) bool { return active(views[i]).After(active(views[j])) })
	main := map[string]any{"id": roomID.String(), "title": "Main"}
	if last := s.lastRoomMessage(ctx, roomID); last != nil {
		main["last"] = map[string]any{"body": clipTrace(last.Body, 160), "sender_id": last.SenderID.String(), "created_at": last.CreatedAt}
	}
	return helper.JSON(map[string]any{"room": roomID.String(), "main": main, "threads": views})
}

func (s *Service) threadCreate(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Room  string `json:"room"`
		Title string `json:"title"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	roomID, err := identity.Parse(in.Room)
	if err != nil {
		return nil, errs.InvalidArgument("invalid room id")
	}
	roomID = s.mainRoom(ctx, roomID)
	if err := s.Can(ctx, spID, roomID, req.Caller.ID, permission.RoomSend); err != nil {
		return nil, err
	}
	thread, err := s.CreateThread(ctx, spID, roomID, req.Caller.ID, in.Title, false)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"thread": s.threadView(ctx, thread)})
}

func (s *Service) threadRename(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Thread string `json:"thread"`
		Title  string `json:"title"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	title := clipTitle(in.Title)
	if title == "" {
		return nil, errs.InvalidArgument("title required")
	}
	thread, err := s.threadRoom(ctx, req.Caller.ID, in.Thread, permission.RoomManage)
	if err != nil {
		return nil, err
	}
	thread.Name = title
	thread.UpdatedAt = time.Now().UTC()
	if err := s.R.Update(ctx, "rooms", thread.ID, thread); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"thread": s.threadView(ctx, thread)})
}

func (s *Service) threadDelete(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Thread string `json:"thread"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	thread, err := s.threadRoom(ctx, req.Caller.ID, in.Thread, permission.RoomManage)
	if err != nil {
		return nil, err
	}
	if err := s.DeleteThread(ctx, thread); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}
