package users

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/crypto"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// What is left of the person's Aseman acting through the node's own tools.
// Aseman now acts on the agent runtime (DeepSeek Harness), as the person and
// with their access, asking with ask_user before anything that cannot be
// undone. What stays here serves what answers already hold: cards under an
// answer, proposals older answers stored (users.brain_confirm can still say
// no to them; their steps no longer run), reminders set before, and taking a
// note up again after an out-of-credits answer.

// plainError is an error as the person is told it: its message, without its cause.
func plainError(err error) string {
	var e *errs.Error
	if errors.As(err, &e) && e.Message != "" {
		return e.Message
	}
	return err.Error()
}

func clip(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n]) + "…"
	}
	return s
}

// ── proposals ───────────────────────────────────────────────────────────────

const (
	proposalPending   = "pending"
	proposalDone      = "done"
	proposalShown     = "shown" // no steps: only cards under the answer
	proposalFailed    = "failed"
	proposalCancelled = "cancelled"
)

// proposalFresh is how long a proposal waits for a yes.
const proposalFresh = 24 * time.Hour

// brainStep is one proposed action.
type brainStep struct {
	Tool    string         `json:"tool"`
	Args    map[string]any `json:"args"`
	Summary string         `json:"summary"`
}

// brainProposal is what an answer proposed, and what became of it.
type brainProposal struct {
	Steps  []brainStep `json:"steps"`
	Status string      `json:"status"`
	Result string      `json:"result,omitempty"`
	// Cards are shown under the answer (brain_cards.go): what a confirmed step made, or what a tool showed.
	Cards []brainCard `json:"cards,omitempty"`
}

// proposalView is a proposal as the app shows it.
func proposalView(raw string) map[string]any {
	var p brainProposal
	if raw == "" || json.Unmarshal([]byte(raw), &p) != nil || (len(p.Steps) == 0 && len(p.Cards) == 0) {
		return nil
	}
	steps := make([]string, len(p.Steps))
	for i, st := range p.Steps {
		steps[i] = st.Summary
	}
	v := map[string]any{"steps": steps, "status": p.Status}
	if p.Result != "" {
		v["result"] = p.Result
	}
	if len(p.Cards) > 0 {
		v["cards"] = p.Cards
	}
	return v
}

// encodeProposal is what an answer stores of its proposals ("" when none).
func encodeProposal(steps []brainStep, cards []brainCard) string {
	if len(steps) == 0 && len(cards) == 0 {
		return ""
	}
	p := brainProposal{Steps: steps, Status: proposalPending, Cards: cards}
	if len(steps) == 0 {
		p.Status = proposalShown
	}
	raw, _ := json.Marshal(p)
	return string(raw)
}

// pendingProposal is the newest answer in the person's notes still waiting for
// a yes, if any.
func (s *Service) pendingProposal(ctx context.Context, me identity.ID) (*message.Direct, *brainProposal) {
	var rows []message.Direct
	if err := s.R.List(ctx, "directs", database.Filter{
		Equal:   map[string]any{"from_id": me.String(), "to_id": me.String()},
		OrderBy: "created_at", Asc: false, Limit: 6,
	}, &rows); err != nil {
		return nil, nil
	}
	for i := range rows {
		dm := &rows[i]
		if dm.AgentID == "" || !dm.DeletedAt.IsZero() {
			continue // the person's own notes (the yes itself among them)
		}
		// Only Aseman's latest answer can be answered with a word.
		if dm.Action == "" || time.Since(dm.CreatedAt) > proposalFresh {
			return nil, nil
		}
		s.openDirect(dm)
		var p brainProposal
		if json.Unmarshal([]byte(dm.Action), &p) == nil && p.Status == proposalPending {
			return dm, &p
		}
		return nil, nil
	}
	return nil, nil
}

var (
	sayYes = regexp.MustCompile(`(?i)^\s*(yes|yep|yeah|y|ok|okay|sure|confirm(ed)?|do it|go ahead|go|please do|بله|آره|باشه|انجام بده)\s*[.!]*\s*$`)
	sayNo  = regexp.MustCompile(`(?i)^\s*(no|nope|n|cancel|don'?t|stop|نه|لغو|نکن)\s*[.!]*\s*$`)
)

// resolve answers a proposal an older answer stored. Cancelling records it;
// a yes cannot carry the steps out any more (Aseman acts on the agent runtime
// now), so the person is told to ask again.
func (s *Service) resolve(ctx context.Context, me identity.ID, dm *message.Direct, p *brainProposal, approve bool) (string, error) {
	if !approve {
		p.Status, p.Result = proposalCancelled, "Cancelled."
	} else {
		p.Status, p.Result = proposalFailed, "This was proposed by an earlier version of Aseman and can no longer run: ask again and it will do it."
	}
	if err := s.setProposal(ctx, dm.ID, p); err != nil {
		return "", err
	}
	return p.Result, nil
}

// setProposal stores what became of a proposal. Only the sealed action changes.
func (s *Service) setProposal(ctx context.Context, id identity.ID, p *brainProposal) error {
	var dm message.Direct
	if err := s.R.Get(ctx, "directs", id, &dm); err != nil {
		return err
	}
	raw, _ := json.Marshal(p)
	sealed, err := s.sealAction(id, string(raw))
	if err != nil {
		return err
	}
	dm.Action, dm.UpdatedAt = sealed, time.Now().UTC()
	return s.R.Update(ctx, "directs", dm.ID, &dm)
}

// brainConfirmAction users.brain_confirm: yes or no to what your Aseman proposed.
func brainConfirmAction(s *Service) api.Action {
	return helper.Action{Namespace: "users", Name: "brain_confirm", Summary: "Confirm (or cancel) what your Aseman proposed to do",
		Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireUser(req); err != nil {
				return nil, err
			}
			var in struct {
				Message string `json:"message"`
				Approve bool   `json:"approve"`
			}
			if err := helper.Decode(req, &in); err != nil {
				return nil, err
			}
			me := req.Caller.ID
			id, err := identity.Parse(in.Message)
			if err != nil {
				return nil, errs.InvalidArgument("message required")
			}
			dm, err := s.getDirect(ctx, id)
			if err != nil || dm.From != me || dm.To != me || dm.AgentID == "" || dm.Action == "" {
				return nil, errs.NotFound("proposal")
			}
			var p brainProposal
			if json.Unmarshal([]byte(dm.Action), &p) != nil || p.Status != proposalPending {
				return nil, errs.Conflict("that was already answered")
			}
			if time.Since(dm.CreatedAt) > proposalFresh {
				return nil, errs.Conflict("that proposal is too old: ask again")
			}
			steps := make([]string, len(p.Steps))
			for i, st := range p.Steps {
				steps[i] = st.Summary
			}
			started := time.Now()
			result, err := s.resolve(helper.WithActor(ctx, me), me, dm, &p, in.Approve)
			// The admin's AI log shows the button too (a reply of yes is logged where it is read).
			confirmed := aiEntry{person: me, kind: aiKindAseman, plan: "confirm", prompt: map[bool]string{true: "Confirmed: ", false: "Cancelled: "}[in.Approve] + strings.Join(steps, "; "),
				answer: result, status: aiAction, started: started, err: err}
			if err != nil || p.Status == proposalFailed {
				confirmed.status = aiError
			}
			s.logAI(context.WithoutCancel(ctx), confirmed)
			if err != nil {
				return nil, err
			}
			return helper.JSON(map[string]any{"ok": true, "status": p.Status, "result": result})
		}}
}

// ── reminders ───────────────────────────────────────────────────────────────

// brainReminder is one reminder (brain_reminders).
type brainReminder struct {
	ID        string    `db:"id" json:"id"`
	Person    string    `db:"person" json:"person"`
	DueAt     time.Time `db:"due_at" json:"due_at"`
	Text      string    `db:"text" json:"-"` // sealed
	Status    string    `db:"status" json:"status"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
}

const (
	reminderWaiting = "waiting"
	reminderSent    = "sent"
	reminderEvery   = 20 * time.Second
	maxReminders    = 100
)

func reminderContext(id string) string { return "users/brain-reminder/v1/" + id }

func (s *Service) openReminder(r *brainReminder) {
	if plain, err := crypto.OpenSecret(r.Text, s.K.Env()["node_private_key"], reminderContext(r.ID)); err == nil {
		r.Text = plain
	} else {
		r.Text = ""
	}
}

// reminders are the person's reminders still to come, soonest first.
func (s *Service) reminders(ctx context.Context, me identity.ID) ([]brainReminder, error) {
	var rows []brainReminder
	if err := s.R.List(ctx, "brain_reminders", database.Filter{
		Equal: map[string]any{"person": me.String(), "status": reminderWaiting}, OrderBy: "due_at", Asc: true,
	}, &rows); err != nil {
		return nil, err
	}
	for i := range rows {
		s.openReminder(&rows[i])
	}
	return rows, nil
}

// deliverReminders writes every reminder that is due into its person's notes,
// as their Aseman, and tells their phone.
func (s *Service) deliverReminders(ctx context.Context, now time.Time) {
	var due []brainReminder
	if err := s.R.List(ctx, "brain_reminders", database.Filter{
		Equal: map[string]any{"status": reminderWaiting}, LessThan: map[string]any{"due_at": now}, OrderBy: "due_at", Asc: true, Limit: 200,
	}, &due); err != nil {
		return
	}
	rec, err := s.assistant(ctx)
	if err != nil {
		return
	}
	for i := range due {
		r := due[i]
		r.Status = reminderSent
		if err := s.R.DB.Update(ctx, "brain_reminders", r.ID, &r); err != nil {
			continue // another node took it, or the database is away: next round
		}
		s.openReminder(&r)
		person, err := identity.Parse(r.Person)
		if err != nil || r.Text == "" {
			continue
		}
		id, err := identity.New(s.K.NodeID())
		if err != nil {
			continue
		}
		body := "⏰ " + r.Text
		dm := &message.Direct{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, From: person, To: person, Body: body, SentAt: now, AgentID: rec.AccountID.String()}
		if err := s.storeDirect(ctx, dm); err != nil {
			s.warn("brain: reminder", person, err)
			continue
		}
		s.logAI(context.WithoutCancel(ctx), aiEntry{person: person, kind: aiKindAseman, plan: "reminder", prompt: r.Text, answer: body, status: aiOK})
		s.Push(ctx, []identity.ID{person}, PushNote{Title: "Aseman", Body: clip(r.Text, 140), Kind: "dm", Peer: person.String(), Collapse: "reminder:" + r.ID})
	}
}

var remindersOnce sync.Once

// startReminders delivers reminders as they fall due, for as long as the node runs.
func (s *Service) startReminders() {
	remindersOnce.Do(func() {
		go func() {
			tick := time.NewTicker(reminderEvery)
			defer tick.Stop()
			for now := range tick.C {
				s.deliverReminders(context.Background(), now.UTC())
			}
		}()
	})
}

// ── out of credits ──────────────────────────────────────────────────────────

// brainRetryAction users.brain_retry: after adding credits, the note an
// out-of-credits answer stands for is taken up again. The answer goes (it has
// done its job); if the wallet still cannot pay, nothing changes and the person is told.
func brainRetryAction(s *Service) api.Action {
	return helper.Action{Namespace: "users", Name: "brain_retry", Summary: "Have your Aseman take up a note it could not answer for lack of credits",
		Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireUser(req); err != nil {
				return nil, err
			}
			var in struct {
				Message string `json:"message"`
			}
			if err := helper.Decode(req, &in); err != nil {
				return nil, err
			}
			me := req.Caller.ID
			id, err := identity.Parse(in.Message)
			if err != nil {
				return nil, errs.InvalidArgument("message required")
			}
			card, err := s.getDirect(ctx, id)
			if err != nil || card.From != me || card.To != me || card.AgentID == "" || card.Brain != message.BrainCredits || !card.DeletedAt.IsZero() {
				return nil, errs.NotFound("message")
			}
			noteID, err := identity.Parse(card.ReplyTo)
			if err != nil {
				return nil, errs.NotFound("the note is no longer there")
			}
			note, err := s.getDirect(ctx, noteID)
			if err != nil || note.From != me || note.To != me || !note.DeletedAt.IsZero() {
				return nil, errs.NotFound("the note is no longer there")
			}
			rec, err := s.assistant(ctx)
			if err != nil {
				return nil, err
			}
			if err := s.canPay(ctx, me, rec); err != nil {
				return nil, err
			}
			s.retire(ctx, card.ID)
			s.startBrain(ctx, me, brainNote{msg: note})
			return helper.JSON(map[string]any{"ok": true})
		}}
}

// canPay checks the person's wallet can pay for an answer now.
func (s *Service) canPay(ctx context.Context, me identity.ID, rec *bot.Bot) error {
	if s.fundsFn != nil {
		return s.fundsFn(ctx, me)
	}
	return bridge.Invoke(ctx, s.K, "bots", "EnsureFunds", []any{ctx, me, rec.ID})
}

// retire takes an answer of Aseman's out of the chat (it has done its job).
func (s *Service) retire(ctx context.Context, id identity.ID) {
	var dm message.Direct
	if err := s.R.Get(ctx, "directs", id, &dm); err != nil {
		return
	}
	now := time.Now().UTC()
	dm.DeletedAt, dm.UpdatedAt = now, now
	if err := s.R.Update(ctx, "directs", dm.ID, &dm); err != nil && s.L != nil {
		s.L.Warn("brain: retire answer", "id", id.String(), "error", err)
	}
}
