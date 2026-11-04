package spaces

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/spaces/models/turn"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// A person's Aseman (users: their notes to themselves) knows the rooms
// they let it read. It sees what the person sees, as the person: a room they
// belong to, its name and what was said in it lately. Which rooms it may read
// is the person's choice, kept in the users namespace.

// BrainRoom is a room (a project) a person belongs to.
type BrainRoom struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	// Owner: the person owns it (their own rooms are readable unless they say no).
	Owner bool `json:"owner"`
	Home  bool `json:"home,omitempty"`
}

// BrainLine is one message of a room, as a person's Aseman is shown it.
type BrainLine struct {
	From string    `json:"from"`
	Body string    `json:"body"`
	At   time.Time `json:"at"`
}

// brainLineChars is how much of one room message the brain is shown.
const brainLineChars = 400

// BrainRooms are the rooms a person belongs to, the ones they joined last first.
func (s *Service) BrainRooms(ctx context.Context, member identity.ID) ([]BrainRoom, error) {
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{
		Equal:   map[string]any{"member_id": member.String(), "room_id": zeroRoom},
		OrderBy: "created_at", Asc: false, Limit: 200,
	}, &mems); err != nil {
		return nil, err
	}
	out := []BrainRoom{}
	for _, m := range mems {
		sp, err := s.GetSpace(ctx, m.SpaceID)
		if err != nil {
			continue
		}
		out = append(out, BrainRoom{ID: sp.ID.String(), Name: sp.Name, Description: sp.Description, Owner: sp.OwnerID == member, Home: sp.Home})
	}
	return out, nil
}

// brainSubmit starts a turn for actor in a space's main thread for its lead,
// who brings in whoever it needs, as if the person had written it there.
func (s *Service) brainSubmit(ctx context.Context, actor, spaceID identity.ID, body string) (*turn.Turn, error) {
	if ok, _ := s.MemberOf(ctx, spaceID, actor); !ok {
		return nil, errs.NotFound("room")
	}
	var rooms []space.Room
	if err := s.R.List(ctx, "rooms", database.Filter{Equal: map[string]any{"space_id": spaceID.String()},
		OrderBy: "created_at", Asc: true, Limit: 1}, &rooms); err != nil {
		return nil, err
	}
	if len(rooms) == 0 {
		return nil, errs.NotFound("this workspace has no conversation yet")
	}
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "role": string(membership.RoleBot)},
	}, &mems); err != nil {
		return nil, err
	}
	lead := ""
	for i := range mems {
		if rec, err := s.botForMember(ctx, mems[i].MemberID); err == nil && rec.IsBuiltinLead() {
			lead = rec.ID.String()
		}
	}
	if lead == "" {
		return nil, errs.NotFound("this workspace has no lead to give the work to")
	}
	return s.SubmitRoomTurn(ctx, actor, spaceID, rooms[0].ID, "", body, "", []string{lead}, nil, false)
}

// BrainWorkStart is where a person's Aseman put work: their home workspace
// and the turn its team works on it in.
type BrainWorkStart struct {
	SpaceID string `json:"space_id"`
	Name    string `json:"name"`
	TurnID  string `json:"turn_id"`
}

// BrainWork hands work to the person's home Aseman (made now if they have
// none): its lead and team take it up on that same space's computer — the
// personal Aseman chat is the home workspace. The turn is the person's own,
// so their budget and permissions apply.
func (s *Service) BrainWork(ctx context.Context, actor identity.ID, request string) (BrainWorkStart, error) {
	home, err := s.PersonalComputer(ctx, actor)
	if err != nil {
		return BrainWorkStart{}, err
	}
	t, err := s.brainSubmit(ctx, actor, home.ID, request)
	if err != nil {
		return BrainWorkStart{}, err
	}
	return BrainWorkStart{SpaceID: home.ID.String(), Name: home.Name, TurnID: t.ID.String()}, nil
}

// BrainTurnResult is how a turn stands: finished or not, and what its team said last.
type BrainTurnResult struct {
	Finished bool   `json:"finished"`
	Status   string `json:"status"`
	Error    string `json:"error,omitempty"`
	// Reply is the last thing someone other than the person said in the room's conversation since the turn began.
	Reply string `json:"reply,omitempty"`
}

// BrainTurn reports on a turn started for a person (only their own).
func (s *Service) BrainTurn(ctx context.Context, actor identity.ID, turnID string) (BrainTurnResult, error) {
	id, err := identity.Parse(turnID)
	if err != nil {
		return BrainTurnResult{}, errs.InvalidArgument("turn")
	}
	var t turn.Turn
	if err := s.R.Get(ctx, "room_turns", id, &t); err != nil || t.ActorID != actor {
		return BrainTurnResult{}, errs.NotFound("turn")
	}
	if _, err := s.GetSpace(ctx, t.SpaceID); err != nil {
		return BrainTurnResult{}, errs.NotFound("workspace")
	}
	out := BrainTurnResult{Status: t.Status, Error: t.Error}
	switch t.Status {
	case "done", "failed", "cancelled":
		out.Finished = true
	}
	if !out.Finished {
		return out, nil
	}
	var recent []message.Message
	if err := s.R.List(ctx, "messages", database.Filter{Equal: map[string]any{"space_id": t.SpaceID.String(), "room_id": t.RoomID.String()},
		OrderBy: "created_at", Asc: false, Limit: 30}, &recent); err != nil {
		return out, nil
	}
	for _, m := range recent {
		if m.CreatedAt.Before(t.CreatedAt) {
			break
		}
		if m.Kind == message.KindLog || m.Kind == message.KindTool || m.Body == "" || m.SenderID == actor {
			continue
		}
		out.Reply = m.Body
		break
	}
	return out, nil
}

// BrainLines are the latest conversation messages of a room (at most n, oldest
// first), for a member of it only: no agent work logs or tool output.
func (s *Service) BrainLines(ctx context.Context, member, spaceID identity.ID, n int) ([]BrainLine, error) {
	if ok, _ := s.MemberOf(ctx, spaceID, member); !ok {
		return nil, nil
	}
	var recent []message.Message
	if err := s.R.List(ctx, "messages", database.Filter{Equal: map[string]any{"space_id": spaceID.String()},
		OrderBy: "created_at", Asc: false, Limit: n * 3}, &recent); err != nil {
		return nil, err
	}
	people := s.participants()
	var newestFirst []BrainLine
	for _, m := range recent {
		if m.Kind == message.KindLog || m.Kind == message.KindTool || m.Body == "" {
			continue
		}
		body := m.Body
		if r := []rune(body); len(r) > brainLineChars {
			body = string(r[:brainLineChars]) + "…"
		}
		from, _ := people.get(ctx, m.SenderID)["display_name"].(string)
		newestFirst = append(newestFirst, BrainLine{From: from, Body: body, At: m.CreatedAt})
		if len(newestFirst) == n {
			break
		}
	}
	out := make([]BrainLine, 0, len(newestFirst))
	for i := len(newestFirst) - 1; i >= 0; i-- {
		out = append(out, newestFirst[i])
	}
	return out, nil
}
