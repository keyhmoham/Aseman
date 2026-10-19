package users

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	market "github.com/tradera/tradera/plugins/actions/market/models"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
)

// Agents in a person's own notes (Saved Messages): a note that mentions a
// market agent is answered by it, quickly, with the agent's instructions and
// model only (no computer, no memory, nothing from the person's rooms). The
// answer is stored in the notes as a reply to the note, marked with the agent.

// savedAskTimeout bounds one answer; a quick question that takes longer is not one.
const savedAskTimeout = 3 * time.Minute

// maxSavedAsks is how many answers one person can be waiting for at once.
const maxSavedAsks = 3

// savedAsk is an answer being written: the note it answers and its agent.
type savedAsk struct {
	note  string
	agent identity.ID
	since time.Time
}

// savedAsks are the answers being written now, per person (in memory: a
// restart drops the "working" state, never an answer already stored).
var savedAsks = struct {
	sync.Mutex
	by map[identity.ID][]savedAsk
}{by: map[identity.ID][]savedAsk{}}

// startSavedAsk records an answer being written, unless the person already
// waits for as many as allowed. Entries older than the timeout are dropped.
func startSavedAsk(person identity.ID, ask savedAsk) bool {
	savedAsks.Lock()
	defer savedAsks.Unlock()
	live := savedAsks.by[person][:0]
	for _, a := range savedAsks.by[person] {
		if time.Since(a.since) < savedAskTimeout+30*time.Second {
			live = append(live, a)
		}
	}
	if len(live) >= maxSavedAsks {
		savedAsks.by[person] = live
		return false
	}
	savedAsks.by[person] = append(live, ask)
	return true
}

func endSavedAsk(person identity.ID, note string) {
	savedAsks.Lock()
	defer savedAsks.Unlock()
	live := savedAsks.by[person][:0]
	for _, a := range savedAsks.by[person] {
		if a.note != note {
			live = append(live, a)
		}
	}
	if len(live) == 0 {
		delete(savedAsks.by, person)
	} else {
		savedAsks.by[person] = live
	}
}

// workingSavedAsks are the answers person is waiting for, for their notes' view.
func (s *Service) workingSavedAsks(ctx context.Context, person identity.ID) []map[string]any {
	savedAsks.Lock()
	asks := append([]savedAsk(nil), savedAsks.by[person]...)
	savedAsks.Unlock()
	out := []map[string]any{}
	for _, a := range asks {
		if time.Since(a.since) < savedAskTimeout+30*time.Second {
			out = append(out, map[string]any{"message_id": a.note, "agent": s.publicRef(ctx, person, a.agent), "since": a.since})
		}
	}
	return out
}

// usableAgent is the agent bot a person may ask from their notes: one listed
// on the market, or one of their own.
func (s *Service) usableAgent(ctx context.Context, person identity.ID, ref string) (*bot.Bot, error) {
	id, err := identity.Parse(ref)
	if err != nil {
		return nil, errs.InvalidArgument("agent required")
	}
	var rec bot.Bot
	if err := s.R.Get(ctx, "bots", id, &rec); err != nil {
		return nil, errs.NotFound("that agent is not there")
	}
	if rec.Kind != bot.KindAgent {
		return nil, errs.InvalidArgument(rec.Name + " is not an agent")
	}
	if rec.OwnerID == person {
		return &rec, nil
	}
	var listings []market.Listing
	if err := s.R.List(ctx, "market", database.Filter{Equal: map[string]any{"bot_id": rec.ID.String(), "status": string(market.StatusActive)}, Limit: 1}, &listings); err != nil || len(listings) == 0 {
		return nil, errs.New(errs.CodePermission, rec.Name+" is not on the market")
	}
	return &rec, nil
}

// savedAskPrompt is what the agent is given: the note, and the note it
// replies to when there is one (the only context it gets).
func savedAskPrompt(note, about string) string {
	var b strings.Builder
	b.WriteString("A quick request from the person's own notes. Answer it directly in your reply, in the chat; there is no computer or files here.\n\n")
	if strings.TrimSpace(about) != "" {
		b.WriteString("The note it is about:\n\"\"\"\n" + about + "\n\"\"\"\n\n")
	}
	b.WriteString("Their request:\n" + note)
	return b.String()
}

// dmAgentAskAction users.dm_agent_ask: an agent answers one of the caller's own notes.
type dmAgentAskAction struct{ s *Service }

func (a *dmAgentAskAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "dm_agent_ask", Summary: "Have a market agent answer one of your own notes (Saved Messages)"}
}

func (a *dmAgentAskAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Message string `json:"message"`
		Agent   string `json:"agent"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	me := req.Caller.ID
	noteID, err := identity.Parse(in.Message)
	if err != nil {
		return nil, errs.InvalidArgument("message required")
	}
	note, err := a.s.getDirect(ctx, noteID)
	if err != nil || note.From != me || note.To != me || !note.DeletedAt.IsZero() {
		return nil, errs.InvalidArgument("agents answer your own notes only")
	}
	if note.AgentID != "" {
		return nil, errs.InvalidArgument("that is an agent's answer")
	}
	rec, err := a.s.usableAgent(ctx, me, in.Agent)
	if err != nil {
		return nil, err
	}
	about := ""
	if note.ReplyTo != "" {
		if rid, err := identity.Parse(note.ReplyTo); err == nil {
			if orig, err := a.s.getDirect(ctx, rid); err == nil && orig.From == me && orig.To == me && orig.DeletedAt.IsZero() {
				about = orig.Body
			}
		}
	}
	if !startSavedAsk(me, savedAsk{note: note.ID.String(), agent: rec.AccountID, since: time.Now().UTC()}) {
		return nil, errs.Conflict("wait for your agents to answer first")
	}
	go a.s.answerSavedAsk(helper.WithActor(context.WithoutCancel(ctx), me), me, rec, note.ID.String(), savedAskPrompt(note.Body, about))
	return helper.JSON(map[string]any{"ok": true})
}

// answerSavedAsk runs the agent and stores its answer in the person's notes,
// as a reply to the note. A failure is answered too, so the person is never
// left waiting on a note nobody will answer.
func (s *Service) answerSavedAsk(ctx context.Context, me identity.ID, rec *bot.Bot, noteID, prompt string) {
	defer endSavedAsk(me, noteID)
	ctx, cancel := context.WithTimeout(ctx, savedAskTimeout)
	defer cancel()
	var reply string
	err := bridge.Invoke(ctx, s.K, "bots", "ChatAnswer", []any{ctx, me, rec.ID, prompt}, &reply)
	reply = strings.TrimSpace(reply)
	if err != nil {
		if s.L != nil {
			s.L.Warn("saved note agent answer failed", "bot", rec.ID.String(), "error", err)
		}
		why := "something went wrong"
		switch {
		case errs.CodeOf(err) == errs.CodeFinance || errs.CodeOf(err) == errs.CodeBudgetExhausted || strings.Contains(strings.ToLower(err.Error()), "fund"):
			why = "your wallet needs credits"
		case ctx.Err() != nil:
			why = "it took too long"
		}
		reply = strings.TrimSpace(reply + "\n\n_(I couldn't finish: " + why + ".)_")
	}
	if reply == "" {
		return
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return
	}
	now := time.Now().UTC()
	dm := &message.Direct{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, From: me, To: me, Body: reply, SentAt: now, ReplyTo: noteID, AgentID: rec.AccountID.String()}
	if err := s.storeDirect(context.WithoutCancel(ctx), dm); err != nil && s.L != nil {
		s.L.Warn("store saved note agent answer", "bot", rec.ID.String(), "error", err)
	}
}
