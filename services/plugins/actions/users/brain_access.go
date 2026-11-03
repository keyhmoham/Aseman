package users

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Which rooms a person's Aseman may read, and what it knows of them.
//
// A room is readable when the person says so, per room (users.brain_room_set);
// with no choice made, the rooms they own are and the others are not. It reads
// a room as the person would: its name, what was said lately and its shared
// notes, and only for a note about their rooms (brain.go). The person sees and
// edits what it knows of them (users.brain_memory_get / brain_memory_set).

// brainRoom is a room as the spaces namespace lists it (spaces.BrainRoom).
type brainRoom struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Owner       bool   `json:"owner"`
	Home        bool   `json:"home,omitempty"`
}

// brainLine is a room message (spaces.BrainLine).
type brainLine struct {
	From string    `json:"from"`
	Body string    `json:"body"`
	At   time.Time `json:"at"`
}

// brainRoomView is a room the brain may read, with what it read of it.
type brainRoomView struct {
	brainRoom
	Notes string
	Lines []brainLine
}

// brainAccess is one person's choices (brain_access, id = account id).
type brainAccess struct {
	ID        string    `db:"id" json:"id"`
	Rooms     string    `db:"rooms" json:"-"` // JSON: space id → readable
	UpdatedAt time.Time `db:"updated_at" json:"-"`
}

// brainChoices are a person's per-room choices (none made: empty).
func (s *Service) brainChoices(ctx context.Context, me identity.ID) map[string]bool {
	var row brainAccess
	out := map[string]bool{}
	if err := s.R.GetString(ctx, "brain_access", me.String(), &row); err == nil && row.Rooms != "" {
		_ = json.Unmarshal([]byte(row.Rooms), &out)
	}
	return out
}

// readable reports whether the brain may read a room, given the person's choices.
func readable(choices map[string]bool, r brainRoom) bool {
	if v, ok := choices[r.ID]; ok {
		return v
	}
	return r.Owner
}

func (s *Service) setBrainChoice(ctx context.Context, me identity.ID, space string, allowed bool) error {
	choices := s.brainChoices(ctx, me)
	choices[space] = allowed
	raw, _ := json.Marshal(choices)
	row := brainAccess{ID: me.String(), Rooms: string(raw), UpdatedAt: time.Now().UTC()}
	if err := s.R.DB.Update(ctx, "brain_access", row.ID, &row); err != nil {
		return s.R.DB.Create(ctx, "brain_access", row.ID, &row)
	}
	return nil
}

// brainRoomsOf are the rooms a person belongs to.
func (s *Service) brainRoomsOf(ctx context.Context, me identity.ID) ([]brainRoom, error) {
	if s.roomsFn != nil {
		return s.roomsFn(ctx, me)
	}
	var out []brainRoom
	err := bridge.Invoke(ctx, s.K, "spaces", "BrainRooms", []any{ctx, me}, &out)
	return out, err
}

func (s *Service) brainLinesOf(ctx context.Context, me identity.ID, space string) []brainLine {
	if s.linesFn != nil {
		return s.linesFn(ctx, me, space)
	}
	id, err := identity.Parse(space)
	if err != nil {
		return nil
	}
	var out []brainLine
	_ = bridge.Invoke(ctx, s.K, "spaces", "BrainLines", []any{ctx, me, id, brainRoomLines}, &out)
	return out
}

// brainRoomContext is every room the person's Aseman may read, by name, with
// what was said lately and the shared notes of the most active of them
// (brainRooms), within the recall deadline.
func (s *Service) brainRoomContext(ctx context.Context, me identity.ID) []brainRoomView {
	rooms, err := s.brainRoomsOf(ctx, me)
	if err != nil || len(rooms) == 0 {
		return nil
	}
	choices := s.brainChoices(ctx, me)
	var views []brainRoomView
	for _, r := range rooms {
		if readable(choices, r) {
			views = append(views, brainRoomView{brainRoom: r})
		}
	}
	// What was said lately decides which rooms are read in full; a person in
	// many rooms has only a handful active.
	const scan = 2 * brainRooms
	ctx, cancel := context.WithTimeout(ctx, brainRecallTimeout)
	defer cancel()
	mem, _ := s.K.VMMFor(vmm.TypeHarness).(vmm.EngineMemory)
	var wg sync.WaitGroup
	for i := range views {
		if i == scan {
			break
		}
		wg.Add(1)
		go func(v *brainRoomView) {
			defer wg.Done()
			v.Lines = s.brainLinesOf(ctx, me, v.ID)
			if mem == nil || len(v.Lines) == 0 {
				return
			}
			if view, err := mem.EngineMemoryRead(ctx, "harness", v.ID, ""); err == nil {
				v.Notes = clipNotes(view.SpaceNotes, brainRoomNotes)
			}
		}(&views[i])
	}
	wg.Wait()
	latest := func(v brainRoomView) time.Time {
		if len(v.Lines) == 0 {
			return time.Time{}
		}
		return v.Lines[len(v.Lines)-1].At
	}
	sort.SliceStable(views, func(i, j int) bool { return latest(views[i]).After(latest(views[j])) })
	for i := range views {
		if i >= brainRooms {
			views[i].Lines, views[i].Notes = nil, ""
		}
	}
	return views
}

// clipNotes is a room's shared notes on one line each, at most limit characters.
func clipNotes(text string, limit int) string {
	lines := []string{}
	for _, l := range strings.Split(text, "\n") {
		if l = strings.TrimSpace(l); l != "" && !strings.HasPrefix(l, "#") {
			lines = append(lines, l)
		}
	}
	out := strings.Join(lines, " ")
	if r := []rune(out); len(r) > limit {
		out = string(r[:limit]) + "…"
	}
	return out
}

// ── actions ─────────────────────────────────────────────────────────────────

func brainActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "users", Name: "brain_rooms", Summary: "The rooms you belong to, and which of them your Aseman may read",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := helper.RequireUser(req); err != nil {
					return nil, err
				}
				rooms, err := s.brainRoomsOf(ctx, req.Caller.ID)
				if err != nil {
					return nil, err
				}
				choices := s.brainChoices(ctx, req.Caller.ID)
				out := make([]map[string]any, 0, len(rooms))
				for _, r := range rooms {
					out = append(out, map[string]any{"id": r.ID, "name": r.Name, "description": r.Description,
						"owner": r.Owner, "allowed": readable(choices, r)})
				}
				return helper.JSON(map[string]any{"rooms": out})
			}},
		helper.Action{Namespace: "users", Name: "brain_room_set", Summary: "Let your Aseman read a room of yours, or not",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := helper.RequireUser(req); err != nil {
					return nil, err
				}
				var in struct {
					Space   string `json:"space"`
					Allowed bool   `json:"allowed"`
				}
				if err := helper.Decode(req, &in); err != nil {
					return nil, err
				}
				rooms, err := s.brainRoomsOf(ctx, req.Caller.ID)
				if err != nil {
					return nil, err
				}
				member := false
				for _, r := range rooms {
					member = member || r.ID == in.Space
				}
				if !member {
					return nil, errs.NotFound("room")
				}
				if err := s.setBrainChoice(ctx, req.Caller.ID, in.Space, in.Allowed); err != nil {
					return nil, err
				}
				return helper.JSON(map[string]any{"ok": true, "allowed": in.Allowed})
			}},
		helper.Action{Namespace: "users", Name: "brain_memory_get", Summary: "What your Aseman knows of you",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := helper.RequireUser(req); err != nil {
					return nil, err
				}
				if s.brainMemory() == nil {
					return helper.JSON(map[string]any{"available": false, "notes": ""})
				}
				forgetCachedNotes(req.Caller.ID)
				notes, err := s.brainNotes(ctx, req.Caller.ID)
				if err != nil {
					return nil, errs.Wrap(errs.CodeUnavailable, err, "your Aseman's memory is unavailable right now")
				}
				return helper.JSON(map[string]any{"available": true, "notes": notes})
			}},
		helper.Action{Namespace: "users", Name: "brain_memory_set", Summary: "Change what your Aseman knows of you",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := helper.RequireUser(req); err != nil {
					return nil, err
				}
				var in struct {
					Notes string `json:"notes"`
				}
				if err := helper.Decode(req, &in); err != nil {
					return nil, err
				}
				if len(in.Notes) > 4*brainNotesChars {
					return nil, errs.InvalidArgument("that is too long: keep what matters most")
				}
				ov := s.brainMemory()
				if ov == nil {
					return nil, errs.New(errs.CodeUnavailable, "this node keeps no memory")
				}
				notes := strings.TrimSpace(in.Notes) + "\n"
				if err := ov.PersonSetNotes(ctx, req.Caller.ID.String(), notes); err != nil {
					return nil, errs.Wrap(errs.CodeUnavailable, err, "your Aseman's memory is unavailable right now")
				}
				forgetCachedNotes(req.Caller.ID)
				return helper.JSON(map[string]any{"ok": true})
			}},
	}
}
