package timeline

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// observation is one item in Utopia's statements contract (decision 0054):
// things (e), statements (s) and other names (n), dated by doc_time. Pushing
// the same external_id again with the same content changes nothing, so every
// item is keyed by what it says: a changed record is a new observation, never
// an edit of an earlier one.
type observation struct {
	ExternalID string  `json:"external_id"`
	DocTime    string  `json:"doc_time,omitempty"`
	E          [][]any `json:"e"`
	S          [][]any `json:"s"`
	N          [][]any `json:"n"`

	space string
}

// thing is an entity of an observation: its name and kind word.
type thing struct{ name, kind string }

// statement is one dated statement: subject phrase object-or-value.
type statement struct {
	subject    thing
	phrase     string
	object     *thing
	value      string
	qualifiers map[string]string
	when       time.Time
}

func newObservation(space, id string, at time.Time, stmts ...statement) observation {
	o := observation{ExternalID: id, DocTime: stamp(at), E: [][]any{}, S: [][]any{}, N: [][]any{}, space: space}
	seen := map[string]bool{}
	add := func(t thing) {
		if !seen[t.name] {
			seen[t.name] = true
			o.E = append(o.E, []any{t.name, t.kind, true})
		}
	}
	for _, st := range stmts {
		if st.subject.name == "" {
			continue
		}
		add(st.subject)
		q := map[string]string{}
		for k, v := range st.qualifiers {
			if v = strings.TrimSpace(v); v != "" {
				q[k] = v
			}
		}
		var object, value any
		if st.object != nil {
			add(*st.object)
			object = st.object.name
		} else {
			value = st.value
		}
		o.S = append(o.S, []any{nil, st.subject.name, st.phrase, object, value, q, stamp(st.when), nil})
	}
	return o
}

func stamp(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

// feed reads one kind of the node's records in time order and turns each into
// observations. A feed never writes the records it reads: they stay owned by
// their namespaces.
type feed struct {
	name  string
	model string
	// field the cursor follows; records are read in its order.
	field string
	read  func(ctx context.Context, s *Service, since time.Time, limit int) ([]record, error)
}

// record is one record of a feed, at its cursor time.
type record struct {
	at  time.Time
	obs []observation
	// pending: the record is not final yet (a tool still running); the
	// cursor waits for it while it is young.
	pending bool
}

func since(field string, at time.Time, limit int) database.Filter {
	f := database.Filter{OrderBy: field, Asc: true, Limit: limit}
	if !at.IsZero() {
		f.GreaterThan = map[string]any{field: at.Add(-time.Microsecond)}
	}
	return f
}

func feeds() []feed {
	return []feed{turnFeed(), toolFeed(), messageFeed(), usageFeed(), fileFeed(), memberFeed(), roomFeed(), routineFeed(), routineRunFeed()}
}

// --- requests (room turns) ---------------------------------------------------

type turnRow struct {
	ID        string    `db:"id"`
	SpaceID   string    `db:"space_id"`
	RoomID    string    `db:"room_id"`
	ActorID   string    `db:"actor_id"`
	Prompt    string    `db:"prompt"`
	Status    string    `db:"status"`
	Error     string    `db:"error"`
	StartedAt time.Time `db:"started_at"`
	EndedAt   time.Time `db:"ended_at"`
	CreatedAt time.Time `db:"created_at"`
	UpdatedAt time.Time `db:"updated_at"`
}

func turnFeed() feed {
	return feed{name: "requests", model: "room_turns", field: "updated_at", read: func(ctx context.Context, s *Service, at time.Time, limit int) ([]record, error) {
		var rows []turnRow
		if err := s.R.List(ctx, "room_turns", since("updated_at", at, limit), &rows); err != nil {
			return nil, err
		}
		out := make([]record, 0, len(rows))
		for _, r := range rows {
			out = append(out, record{at: r.UpdatedAt, obs: s.turnObservations(ctx, r)})
		}
		return out, nil
	}}
}

func (s *Service) turnObservations(ctx context.Context, r turnRow) []observation {
	if r.SpaceID == "" {
		return nil
	}
	request := s.names.request(r.ID)
	room := s.names.room(ctx, r.RoomID)
	asked := r.CreatedAt
	asks := newObservation(r.SpaceID, "request:"+r.ID, asked,
		statement{subject: s.names.account(ctx, r.ActorID), phrase: "asked for", object: &request, when: asked,
			qualifiers: map[string]string{"request": clip(r.Prompt, 300)}},
		statement{subject: request, phrase: "was asked in", object: &room, when: asked})
	when := r.UpdatedAt
	if !r.EndedAt.IsZero() {
		when = r.EndedAt
	} else if !r.StartedAt.IsZero() && r.Status == "running" {
		when = r.StartedAt
	}
	status := newObservation(r.SpaceID, "request:"+r.ID+":"+r.Status, when,
		statement{subject: request, phrase: "has status", value: r.Status, when: when,
			qualifiers: map[string]string{"error": clip(r.Error, 300)}})
	return []observation{asks, status}
}

// --- tool runs (execution events) --------------------------------------------

type toolRow struct {
	ID        string    `db:"id"`
	SpaceID   string    `db:"space_id"`
	RoomID    string    `db:"room_id"`
	RunID     string    `db:"run_id"`
	AgentID   string    `db:"agent_id"`
	AgentName string    `db:"agent_name"`
	Tool      string    `db:"tool"`
	Status    string    `db:"status"`
	At        time.Time `db:"at"`
}

func toolFeed() feed {
	return feed{name: "tools", model: "execution_events", field: "at", read: func(ctx context.Context, s *Service, at time.Time, limit int) ([]record, error) {
		var rows []toolRow
		if err := s.R.List(ctx, "execution_events", since("at", at, limit), &rows); err != nil {
			return nil, err
		}
		out := make([]record, 0, len(rows))
		for _, r := range rows {
			if r.Status == "running" {
				out = append(out, record{at: r.At, pending: true})
				continue
			}
			if r.SpaceID == "" {
				out = append(out, record{at: r.At})
				continue
			}
			agent := s.names.bot(ctx, r.AgentID, r.AgentName)
			obs := newObservation(r.SpaceID, "tool:"+r.ID+":"+r.Status, r.At,
				statement{subject: agent, phrase: "ran tool", value: r.Tool, when: r.At, qualifiers: map[string]string{
					"status": r.Status, "room": s.names.room(ctx, r.RoomID).name, "run": r.RunID}})
			out = append(out, record{at: r.At, obs: []observation{obs}})
		}
		return out, nil
	}}
}

// --- room messages and agents' work logs ------------------------------------

type messageRow struct {
	ID        string    `db:"id"`
	SpaceID   string    `db:"space_id"`
	RoomID    string    `db:"room_id"`
	SenderID  string    `db:"sender_id"`
	Body      string    `db:"body"`
	Kind      string    `db:"kind"`
	ReplyTo   string    `db:"reply_to"`
	CreatedAt time.Time `db:"created_at"`
}

func messageFeed() feed {
	return feed{name: "messages", model: "messages", field: "created_at", read: func(ctx context.Context, s *Service, at time.Time, limit int) ([]record, error) {
		var rows []messageRow
		if err := s.R.List(ctx, "messages", since("created_at", at, limit), &rows); err != nil {
			return nil, err
		}
		out := make([]record, 0, len(rows))
		for _, r := range rows {
			rec := record{at: r.CreatedAt}
			if r.SpaceID != "" && r.Kind != "tool" {
				sender := s.names.account(ctx, r.SenderID)
				room := s.names.room(ctx, r.RoomID)
				var st statement
				if r.Kind == "log" {
					// An agent's work log: what it planned, ran and found.
					st = statement{subject: sender, phrase: "logged work in", object: &room, when: r.CreatedAt,
						qualifiers: map[string]string{"entry": clip(r.Body, 300)}}
				} else {
					st = statement{subject: sender, phrase: "posted in", object: &room, when: r.CreatedAt,
						qualifiers: map[string]string{"message": clip(r.Body, 200), "reply to": r.ReplyTo, "message id": r.ID}}
				}
				rec.obs = []observation{newObservation(r.SpaceID, "message:"+r.ID, r.CreatedAt, st)}
			}
			out = append(out, rec)
		}
		return out, nil
	}}
}

// --- model usage --------------------------------------------------------------

type usageRow struct {
	ID        string    `db:"id"`
	SpaceID   string    `db:"space_id"`
	RoomID    string    `db:"room_id"`
	BotID     string    `db:"bot_id"`
	BotName   string    `db:"bot_name"`
	ActorID   string    `db:"actor_id"`
	RequestID string    `db:"request_id"`
	Model     string    `db:"model"`
	Kind      string    `db:"kind"`
	TokensIn  int64     `db:"tokens_in"`
	TokensOut int64     `db:"tokens_out"`
	Cost      int64     `db:"cost"`
	CreatedAt time.Time `db:"created_at"`
}

func usageFeed() feed {
	return feed{name: "usage", model: "usages", field: "created_at", read: func(ctx context.Context, s *Service, at time.Time, limit int) ([]record, error) {
		var rows []usageRow
		if err := s.R.List(ctx, "usages", since("created_at", at, limit), &rows); err != nil {
			return nil, err
		}
		out := make([]record, 0, len(rows))
		for _, r := range rows {
			rec := record{at: r.CreatedAt}
			if r.SpaceID != "" && (r.TokensIn > 0 || r.TokensOut > 0) {
				who := s.names.account(ctx, r.ActorID)
				if r.BotID != "" {
					who = s.names.bot(ctx, r.BotID, r.BotName)
				}
				rec.obs = []observation{newObservation(r.SpaceID, "usage:"+r.ID, r.CreatedAt,
					statement{subject: who, phrase: "used tokens", value: strconv.FormatInt(r.TokensIn+r.TokensOut, 10), when: r.CreatedAt,
						qualifiers: map[string]string{"model": r.Model, "tokens in": num(r.TokensIn), "tokens out": num(r.TokensOut),
							"cost": num(r.Cost), "kind": r.Kind, "room": s.names.room(ctx, r.RoomID).name, "request": r.RequestID}})}
			}
			out = append(out, rec)
		}
		return out, nil
	}}
}

func num(n int64) string {
	if n == 0 {
		return ""
	}
	return strconv.FormatInt(n, 10)
}

// --- files --------------------------------------------------------------------

type fileRow struct {
	ID        string    `db:"id"`
	OwnerID   string    `db:"owner_id"`
	SpaceID   string    `db:"space_id"`
	RoomID    string    `db:"room_id"`
	Name      string    `db:"name"`
	Mime      string    `db:"mime"`
	Size      int64     `db:"size"`
	CreatedAt time.Time `db:"created_at"`
}

func fileFeed() feed {
	return feed{name: "files", model: "files", field: "created_at", read: func(ctx context.Context, s *Service, at time.Time, limit int) ([]record, error) {
		var rows []fileRow
		if err := s.R.List(ctx, "files", since("created_at", at, limit), &rows); err != nil {
			return nil, err
		}
		out := make([]record, 0, len(rows))
		for _, r := range rows {
			rec := record{at: r.CreatedAt}
			if r.SpaceID != "" {
				file := &thing{label(r.Name, r.ID), "file"}
				rec.obs = []observation{newObservation(r.SpaceID, "file:"+r.ID, r.CreatedAt,
					statement{subject: s.names.account(ctx, r.OwnerID), phrase: "shared file", object: file, when: r.CreatedAt,
						qualifiers: map[string]string{"room": s.names.room(ctx, r.RoomID).name, "type": r.Mime, "bytes": num(r.Size), "file id": r.ID}})}
			}
			out = append(out, rec)
		}
		return out, nil
	}}
}

// --- members --------------------------------------------------------------------

type memberRow struct {
	ID        string    `db:"id"`
	SpaceID   string    `db:"space_id"`
	RoomID    string    `db:"room_id"`
	MemberID  string    `db:"member_id"`
	Role      string    `db:"role"`
	JoinedAt  time.Time `db:"joined_at"`
	CreatedAt time.Time `db:"created_at"`
}

func memberFeed() feed {
	return feed{name: "members", model: "memberships", field: "created_at", read: func(ctx context.Context, s *Service, at time.Time, limit int) ([]record, error) {
		var rows []memberRow
		if err := s.R.List(ctx, "memberships", since("created_at", at, limit), &rows); err != nil {
			return nil, err
		}
		out := make([]record, 0, len(rows))
		for _, r := range rows {
			rec := record{at: r.CreatedAt}
			if r.SpaceID != "" {
				when := r.JoinedAt
				if when.IsZero() {
					when = r.CreatedAt
				}
				where, phrase := s.names.space(ctx, r.SpaceID), "joined"
				if r.RoomID != "" {
					where, phrase = s.names.room(ctx, r.RoomID), "joined room"
				}
				rec.obs = []observation{newObservation(r.SpaceID, "member:"+r.ID, when,
					statement{subject: s.names.account(ctx, r.MemberID), phrase: phrase, object: &where, when: when,
						qualifiers: map[string]string{"role": r.Role}})}
			}
			out = append(out, rec)
		}
		return out, nil
	}}
}

// --- rooms --------------------------------------------------------------------

type roomRow struct {
	ID        string    `db:"id"`
	SpaceID   string    `db:"space_id"`
	Name      string    `db:"name"`
	Topic     string    `db:"topic"`
	CreatedAt time.Time `db:"created_at"`
}

func roomFeed() feed {
	return feed{name: "rooms", model: "rooms", field: "created_at", read: func(ctx context.Context, s *Service, at time.Time, limit int) ([]record, error) {
		var rows []roomRow
		if err := s.R.List(ctx, "rooms", since("created_at", at, limit), &rows); err != nil {
			return nil, err
		}
		out := make([]record, 0, len(rows))
		for _, r := range rows {
			rec := record{at: r.CreatedAt}
			if r.SpaceID != "" {
				project := s.names.space(ctx, r.SpaceID)
				rec.obs = []observation{newObservation(r.SpaceID, "room:"+r.ID, r.CreatedAt,
					statement{subject: s.names.room(ctx, r.ID), phrase: "was opened in", object: &project,
						when: r.CreatedAt, qualifiers: map[string]string{"topic": clip(r.Topic, 200)}})}
			}
			out = append(out, rec)
		}
		return out, nil
	}}
}

// --- routines -----------------------------------------------------------------

type routineRow struct {
	ID          string    `db:"id"`
	SpaceID     string    `db:"space_id"`
	RoomID      string    `db:"room_id"`
	CreatorID   string    `db:"creator_id"`
	Name        string    `db:"name"`
	Type        string    `db:"type"`
	Target      string    `db:"target"`
	Task        string    `db:"task"`
	IntervalSec int64     `db:"interval_sec"`
	At          string    `db:"at"`
	CreatedAt   time.Time `db:"created_at"`
}

func routineFeed() feed {
	return feed{name: "routines", model: "routines", field: "created_at", read: func(ctx context.Context, s *Service, at time.Time, limit int) ([]record, error) {
		var rows []routineRow
		if err := s.R.List(ctx, "routines", since("created_at", at, limit), &rows); err != nil {
			return nil, err
		}
		out := make([]record, 0, len(rows))
		for _, r := range rows {
			rec := record{at: r.CreatedAt}
			if r.SpaceID != "" {
				routine := &thing{label("routine "+r.Name, r.ID), "routine"}
				rec.obs = []observation{newObservation(r.SpaceID, "routine:"+r.ID, r.CreatedAt,
					statement{subject: s.names.account(ctx, r.CreatorID), phrase: "scheduled", object: routine, when: r.CreatedAt,
						qualifiers: map[string]string{"task": clip(r.Task, 300), "type": r.Type, "every seconds": num(r.IntervalSec),
							"at": r.At, "room": s.names.room(ctx, r.RoomID).name}})}
			}
			out = append(out, rec)
		}
		return out, nil
	}}
}

type routineRunRow struct {
	ID          string    `db:"id"`
	RoutineID   string    `db:"routine_id"`
	SpaceID     string    `db:"space_id"`
	ScheduledAt time.Time `db:"scheduled_at"`
	Status      string    `db:"status"`
	Attempt     int64     `db:"attempt"`
	Result      string    `db:"result"`
	UpdatedAt   time.Time `db:"updated_at"`
}

func routineRunFeed() feed {
	return feed{name: "routine runs", model: "routine_runs", field: "updated_at", read: func(ctx context.Context, s *Service, at time.Time, limit int) ([]record, error) {
		var rows []routineRunRow
		if err := s.R.List(ctx, "routine_runs", since("updated_at", at, limit), &rows); err != nil {
			return nil, err
		}
		out := make([]record, 0, len(rows))
		for _, r := range rows {
			rec := record{at: r.UpdatedAt}
			if r.SpaceID != "" {
				routine := s.names.routine(ctx, r.RoutineID)
				rec.obs = []observation{newObservation(r.SpaceID, "routine run:"+r.ID+":"+r.Status, r.UpdatedAt,
					statement{subject: routine, phrase: "run has status", value: r.Status, when: r.UpdatedAt,
						qualifiers: map[string]string{"scheduled for": stamp(r.ScheduledAt), "attempt": num(r.Attempt), "result": clip(r.Result, 300)}})}
			}
			out = append(out, rec)
		}
		return out, nil
	}}
}

// label names a thing by its name and the end of its id: names repeat (two
// agents called "Researcher"), ids do not.
func label(name, id string) string {
	name = strings.Join(strings.Fields(name), " ")
	short := id
	if len(short) > 6 {
		short = short[len(short)-6:]
	}
	if name == "" {
		name = "unnamed"
	}
	if short == "" {
		return clip(name, 80)
	}
	return clip(name, 80) + " (#" + short + ")"
}
