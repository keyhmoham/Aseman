package users

import (
	"context"
	"sort"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Voice and video calls between two people. The media goes phone to phone
// (WebRTC, encrypted by DTLS-SRTP, relayed only when it must be: turn.go); the
// node only introduces the two phones. A call is one row (who, with video or
// not, and where it stands), and the setup messages the phones swap (the
// offer, the answer, the network candidates) are `call_signals` rows each
// side polls for. Nothing of the media itself ever reaches the node.
//
//	ringing ─ call_accept ─▶ active ─ call_end ─▶ ended
//	   │                                            ▲
//	   └── call_decline / call_end / no answer ─────┘

const (
	callRinging = "ringing"
	callActive  = "active"
	callEnded   = "ended"
)

// ringFor is how long a call rings before it counts as missed.
var ringFor = 45 * time.Second

// activeStale is how long an active call may go unheard from (both phones poll
// every few seconds) before it is taken as over: a phone that lost power or
// signal must not leave the other person "busy" for ever.
const activeStale = 2 * time.Minute

// maxSignal bounds one setup message (an SDP is a few KB).
const maxSignal = 32 << 10

// DirectCall is one call between two people.
type DirectCall struct {
	ID         string    `db:"id" json:"id"`
	CallerID   string    `db:"caller_id" json:"caller_id"`
	CalleeID   string    `db:"callee_id" json:"callee_id"`
	Video      bool      `db:"video" json:"video"`
	State      string    `db:"state" json:"state"`
	EndReason  string    `db:"end_reason" json:"end_reason,omitempty"`
	CreatedAt  time.Time `db:"created_at" json:"created_at"`
	AnsweredAt time.Time `db:"answered_at" json:"-"`
	EndedAt    time.Time `db:"ended_at" json:"-"`
	UpdatedAt  time.Time `db:"updated_at" json:"-"`
}

// CallSignal is one setup message of a call, from one of its two people.
type CallSignal struct {
	ID        string    `db:"id" json:"id"`
	CallID    string    `db:"call_id" json:"-"`
	FromID    string    `db:"from_id" json:"from_id"`
	Kind      string    `db:"kind" json:"kind"` // offer | answer | ice
	Payload   string    `db:"payload" json:"payload"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
}

func callView(c DirectCall) map[string]any {
	v := map[string]any{"id": c.ID, "caller_id": c.CallerID, "callee_id": c.CalleeID, "video": c.Video, "state": c.State, "created_at": c.CreatedAt,
		"answered_at": nullTime(c.AnsweredAt), "ended_at": nullTime(c.EndedAt)}
	if c.EndReason != "" {
		v["end_reason"] = c.EndReason
	}
	return v
}

func callActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "users", Name: "call_start", Summary: "Start a voice or video call to a person", Handler: s.callStart},
		helper.Action{Namespace: "users", Name: "call_incoming", Summary: "The call ringing for the caller, if any", Handler: s.callIncoming},
		helper.Action{Namespace: "users", Name: "call_accept", Summary: "Answer a ringing call", Handler: s.callAccept},
		helper.Action{Namespace: "users", Name: "call_decline", Summary: "Decline a ringing call", Handler: s.callDecline},
		helper.Action{Namespace: "users", Name: "call_end", Summary: "Hang up (or cancel a call that is still ringing)", Handler: s.callEnd},
		helper.Action{Namespace: "users", Name: "call_signal", Summary: "Send a call setup message (offer, answer or network candidate)", Handler: s.callSignal},
		helper.Action{Namespace: "users", Name: "call_poll", Summary: "A call's state and the setup messages from the other side", Handler: s.callPoll},
	}
}

// callOf reads a call the caller takes part in, ending it first if it rang out
// or went quiet.
func (s *Service) callOf(ctx context.Context, id string, me identity.ID) (*DirectCall, error) {
	var c DirectCall
	if err := s.R.GetString(ctx, "direct_calls", id, &c); err != nil {
		return nil, err
	}
	if c.CallerID != me.String() && c.CalleeID != me.String() {
		return nil, errs.New(errs.CodePermission, "not your call")
	}
	s.expireCall(ctx, &c)
	return &c, nil
}

// expireCall ends a call that was not answered in time or has gone quiet.
func (s *Service) expireCall(ctx context.Context, c *DirectCall) {
	now := time.Now().UTC()
	switch {
	case c.State == callRinging && now.Sub(c.CreatedAt) > ringFor:
		_ = s.finishCall(ctx, c, "missed")
	case c.State == callActive && now.Sub(c.UpdatedAt) > activeStale:
		_ = s.finishCall(ctx, c, "lost")
	}
}

func (s *Service) finishCall(ctx context.Context, c *DirectCall, reason string) error {
	if c.State == callEnded {
		return nil
	}
	now := time.Now().UTC()
	ended := now
	if reason == "lost" && !c.UpdatedAt.IsZero() {
		ended = c.UpdatedAt // the last time a phone was heard from, not when the node noticed
	}
	c.State, c.EndReason, c.EndedAt, c.UpdatedAt = callEnded, reason, ended, now
	return s.R.UpdateString(ctx, "direct_calls", c.ID, c)
}

// liveCall is the call a person is in or is being rung for, if any.
func (s *Service) liveCall(ctx context.Context, user identity.ID) (*DirectCall, error) {
	for _, side := range []string{"caller_id", "callee_id"} {
		var rows []DirectCall
		if err := s.R.List(ctx, "direct_calls", database.Filter{Equal: map[string]any{side: user.String()}, OrderBy: "created_at", Asc: false, Limit: 5}, &rows); err != nil {
			return nil, err
		}
		for i := range rows {
			if rows[i].State == callEnded {
				continue
			}
			s.expireCall(ctx, &rows[i])
			if rows[i].State != callEnded {
				return &rows[i], nil
			}
		}
	}
	return nil, nil
}

func (s *Service) callStart(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		To    string `json:"to"`
		Video bool   `json:"video"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	to, err := identity.Parse(in.To)
	if err != nil {
		return nil, err
	}
	me := req.Caller.ID
	if to == me {
		return nil, errs.InvalidArgument("you can't call yourself")
	}
	if blocked, byMe, err := s.directBlocked(ctx, me, to); err != nil {
		return nil, err
	} else if blocked {
		if byMe {
			return nil, errs.Conflict("you blocked this person")
		}
		return nil, errs.Conflict("this person can't be called")
	}
	if err := s.callAllowed(ctx, me, to, in.Video); err != nil {
		return nil, err
	}
	if mine, err := s.liveCall(ctx, me); err != nil {
		return nil, err
	} else if mine != nil {
		return nil, errs.Conflict("you are already in a call")
	}
	if theirs, err := s.liveCall(ctx, to); err != nil {
		return nil, err
	} else if theirs != nil {
		return nil, errs.Conflict("busy")
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	c := &DirectCall{ID: id.String(), CallerID: me.String(), CalleeID: to.String(), Video: in.Video, State: callRinging, CreatedAt: now, UpdatedAt: now}
	if err := s.R.DB.Create(ctx, "direct_calls", c.ID, c); err != nil {
		return nil, err
	}
	go s.ringCallee(context.WithoutCancel(ctx), *c)
	return helper.JSON(map[string]any{"ok": true, "call": callView(*c), "ice_servers": s.iceServers(ctx)})
}

// ringCallee tells the callee's phones, then waits out the ringing: a call
// nobody answered becomes a missed call, which the callee is told about.
func (s *Service) ringCallee(ctx context.Context, c DirectCall) {
	caller, _ := identity.Parse(c.CallerID)
	callee, _ := identity.Parse(c.CalleeID)
	name, _ := s.publicRef(ctx, callee, caller)["display_name"].(string)
	if name == "" {
		name = "Someone"
	}
	kind := "voice"
	if c.Video {
		kind = "video"
	}
	s.Push(ctx, []identity.ID{callee}, PushNote{Title: name, Body: "Incoming " + kind + " call", Kind: "call", Peer: c.CallerID, Collapse: "call:" + c.CallerID})
	time.Sleep(ringFor + time.Second)
	var cur DirectCall
	if err := s.R.GetString(ctx, "direct_calls", c.ID, &cur); err != nil {
		return
	}
	if cur.State == callRinging {
		_ = s.finishCall(ctx, &cur, "missed")
		s.Push(ctx, []identity.ID{callee}, PushNote{Title: name, Body: "Missed " + kind + " call", Kind: "dm", Peer: c.CallerID, Collapse: "call:" + c.CallerID})
	}
}

// callIncoming is the call ringing for the caller, with who is calling. The
// phone asks every few seconds while the app is open.
func (s *Service) callIncoming(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	c, err := s.liveCall(ctx, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	if c == nil || c.CalleeID != req.Caller.ID.String() || c.State != callRinging {
		return helper.JSON(map[string]any{"call": nil})
	}
	caller, _ := identity.Parse(c.CallerID)
	return helper.JSON(map[string]any{"call": callView(*c), "caller": s.publicRef(ctx, req.Caller.ID, caller)})
}

// callWithID reads the call named in the request's "id".
func (s *Service) callWithID(ctx context.Context, req *api.ActionRequest) (*DirectCall, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		ID string `json:"id"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	return s.callOf(ctx, in.ID, req.Caller.ID)
}

func (s *Service) callAccept(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	c, err := s.callWithID(ctx, req)
	if err != nil {
		return nil, err
	}
	if c.CalleeID != req.Caller.ID.String() {
		return nil, errs.New(errs.CodePermission, "only the person called can answer")
	}
	if c.State != callRinging {
		return nil, errs.Conflict("this call is over")
	}
	now := time.Now().UTC()
	c.State, c.AnsweredAt, c.UpdatedAt = callActive, now, now
	if err := s.R.UpdateString(ctx, "direct_calls", c.ID, c); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "call": callView(*c), "ice_servers": s.iceServers(ctx)})
}

func (s *Service) callDecline(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	c, err := s.callWithID(ctx, req)
	if err != nil {
		return nil, err
	}
	if c.CalleeID != req.Caller.ID.String() {
		return nil, errs.New(errs.CodePermission, "only the person called can decline")
	}
	if c.State == callRinging {
		if err := s.finishCall(ctx, c, "declined"); err != nil {
			return nil, err
		}
	}
	return helper.JSON(map[string]any{"ok": true, "call": callView(*c)})
}

func (s *Service) callEnd(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	c, err := s.callWithID(ctx, req)
	if err != nil {
		return nil, err
	}
	if c.State != callEnded {
		reason := "hangup"
		if c.State == callRinging && c.CallerID == req.Caller.ID.String() {
			reason = "cancelled"
		}
		if err := s.finishCall(ctx, c, reason); err != nil {
			return nil, err
		}
	}
	return helper.JSON(map[string]any{"ok": true, "call": callView(*c)})
}

func (s *Service) callSignal(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		ID      string `json:"id"`
		Kind    string `json:"kind"`
		Payload string `json:"payload"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	c, err := s.callOf(ctx, in.ID, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	if c.State == callEnded {
		return nil, errs.Conflict("this call is over")
	}
	me := req.Caller.ID.String()
	switch in.Kind {
	case "offer":
		if c.CallerID != me {
			return nil, errs.New(errs.CodePermission, "only the caller makes the offer")
		}
	case "answer":
		if c.CalleeID != me {
			return nil, errs.New(errs.CodePermission, "only the person called answers")
		}
	case "ice", "state": // state: whether the sender's camera and microphone are on
	default:
		return nil, errs.InvalidArgument("kind must be offer, answer, ice or state")
	}
	if in.Payload == "" || len(in.Payload) > maxSignal {
		return nil, errs.InvalidArgument("payload missing or too large")
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	row := &CallSignal{ID: id.String(), CallID: c.ID, FromID: me, Kind: in.Kind, Payload: in.Payload, CreatedAt: time.Now().UTC()}
	if err := s.R.DB.Create(ctx, "call_signals", row.ID, row); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

// callPoll is a call's state and the setup messages from the other side that
// are newer than `since` (a little earlier is fine: the phone skips ids it has
// seen). While the call is active, polling also shows the node both phones are
// still there.
func (s *Service) callPoll(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		ID    string    `json:"id"`
		Since time.Time `json:"since"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	c, err := s.callOf(ctx, in.ID, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	me := req.Caller.ID.String()
	if c.State == callActive && time.Since(c.UpdatedAt) > 20*time.Second {
		c.UpdatedAt = time.Now().UTC()
		_ = s.R.UpdateString(ctx, "direct_calls", c.ID, c)
	}
	other := c.CalleeID
	if c.CalleeID == me {
		other = c.CallerID
	}
	f := database.Filter{Equal: map[string]any{"call_id": c.ID, "from_id": other}, OrderBy: "created_at", Asc: true, Limit: 200}
	if !in.Since.IsZero() {
		f.GreaterThan = map[string]any{"created_at": in.Since}
	}
	signals := []CallSignal{}
	if err := s.R.List(ctx, "call_signals", f, &signals); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"call": callView(*c), "signals": signals})
}

// callHistory are the finished calls between two people since `after` (the
// time the viewer cleared the chat; zero for never), newest first, for the
// chat to show among the messages.
func (s *Service) callHistory(ctx context.Context, a, b identity.ID, after time.Time, limit int) []map[string]any {
	out := []map[string]any{}
	if a == b {
		return out
	}
	var rows []DirectCall
	for _, pair := range [][2]identity.ID{{a, b}, {b, a}} {
		var part []DirectCall
		f := database.Filter{Equal: map[string]any{"caller_id": pair[0].String(), "callee_id": pair[1].String(), "state": callEnded}, OrderBy: "created_at", Asc: false, Limit: limit}
		if err := s.R.List(ctx, "direct_calls", f, &part); err != nil {
			return out // calls are a garnish: the conversation still loads
		}
		rows = append(rows, part...)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].CreatedAt.After(rows[j].CreatedAt) })
	for _, c := range rows {
		if !after.IsZero() && !c.CreatedAt.After(after) {
			continue
		}
		if len(out) == limit {
			break
		}
		out = append(out, callView(c))
	}
	return out
}
