package users

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/crypto"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Work that needs a computer (research across many sites, running code, building something) is handed to the
// person's own workspace by the work_on_it tool, once they confirm. It takes minutes, so Aseman does not wait:
// a job is kept (brain_jobs) and a loop looks at it every few seconds; when the team has finished, Aseman
// writes in the person's notes what came of it, with a card that opens the workspace, and pushes.

const (
	jobWaiting = "waiting"
	jobDone    = "done"

	jobEvery   = 6 * time.Second
	jobGiveUp  = 45 * time.Minute
	jobReplyAt = 1500

	// jobGone is the error of work whose workspace has been deleted.
	jobGone = "its workspace was deleted"
)

// brainJob is one piece of work handed to a workspace (brain_jobs).
type brainJob struct {
	ID        string    `db:"id" json:"id"`
	Person    string    `db:"person" json:"person"`
	Space     string    `db:"space" json:"space"`
	SpaceName string    `db:"space_name" json:"space_name"`
	Turn      string    `db:"turn" json:"turn"`
	Note      string    `db:"note" json:"note"` // the note the proposal answered
	Request   string    `db:"request" json:"-"` // sealed
	Status    string    `db:"status" json:"status"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
}

func jobContext(id string) string { return "users/brain-job/v1/" + id }

// turnResult is what the spaces plugin says of a turn (spaces.BrainTurnResult).
type turnResult struct {
	Finished bool   `json:"finished"`
	Status   string `json:"status"`
	Error    string `json:"error,omitempty"`
	Reply    string `json:"reply,omitempty"`
}

// workStart is what the spaces plugin says of work it started (spaces.BrainWorkStart).
type workStart struct {
	SpaceID string `json:"space_id"`
	Name    string `json:"name"`
	TurnID  string `json:"turn_id"`
}

func (s *Service) startWork(ctx context.Context, me identity.ID, request string) (workStart, error) {
	if s.workFn != nil {
		return s.workFn(ctx, me, request)
	}
	var out workStart
	err := bridge.Invoke(ctx, s.K, "spaces", "BrainWork", []any{ctx, me, request}, &out)
	return out, err
}

func (s *Service) turnResult(ctx context.Context, me identity.ID, turn string) (turnResult, error) {
	if s.turnFn != nil {
		return s.turnFn(ctx, me, turn)
	}
	var out turnResult
	err := bridge.Invoke(ctx, s.K, "spaces", "BrainTurn", []any{ctx, me, turn}, &out)
	return out, err
}

// addJob keeps work handed to a workspace until the team has finished it.
func (s *Service) addJob(ctx context.Context, me identity.ID, start workStart, request, note string) error {
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	sealed, err := crypto.SealSecret(clip(request, 2000), s.K.Env()["node_private_key"], jobContext(id.String()))
	if err != nil {
		return errs.New(errs.CodeUnavailable, "this node cannot keep the work")
	}
	return s.R.DB.Create(ctx, "brain_jobs", id.String(), &brainJob{ID: id.String(), Person: me.String(), Space: start.SpaceID, SpaceName: start.Name,
		Turn: start.TurnID, Note: note, Request: sealed, Status: jobWaiting, CreatedAt: time.Now().UTC()})
}

// deliverJobs writes into the notes the work whose team has finished (or that has gone on too long).
func (s *Service) deliverJobs(ctx context.Context, now time.Time) {
	var jobs []brainJob
	if err := s.R.List(ctx, "brain_jobs", database.Filter{Equal: map[string]any{"status": jobWaiting}, OrderBy: "created_at", Asc: true, Limit: 50}, &jobs); err != nil {
		return
	}
	for _, j := range jobs {
		person, err := identity.Parse(j.Person)
		if err != nil {
			continue
		}
		res, err := s.turnResult(ctx, person, j.Turn)
		late := now.Sub(j.CreatedAt) > jobGiveUp
		if err != nil && errs.CodeOf(err) == errs.CodeNotFound {
			// The workspace or the turn is gone: say so now, not after the wait.
			s.finishJob(ctx, person, j, turnResult{Finished: true, Status: "failed", Error: jobGone}, true)
			continue
		}
		if err != nil && !late {
			continue
		}
		if err == nil && !res.Finished && !late {
			continue
		}
		s.finishJob(ctx, person, j, res, err == nil && res.Finished)
	}
}

// finishJob tells the person how their work went, and puts it away.
func (s *Service) finishJob(ctx context.Context, me identity.ID, j brainJob, res turnResult, finished bool) {
	j.Status = jobDone
	if err := s.R.DB.Update(ctx, "brain_jobs", j.ID, &j); err != nil {
		s.warn("brain: job", me, err)
		return
	}
	rec, err := s.assistant(ctx)
	if err != nil {
		return
	}
	// The workspace is found by its id, so a new name is the name to show; one that is gone is said to be.
	name, there := j.SpaceName, false
	if rooms, err := s.brainRoomsOf(ctx, me); err == nil {
		for _, r := range rooms {
			if r.ID == j.Space {
				name, there = r.Name, true
			}
		}
	} else {
		there = true // not known: do not say it is gone
	}
	if res.Error == jobGone {
		there = false
	}
	card := brainCard{Type: cardRoom, ID: j.Space, Title: name, Subtitle: "Open to see the work"}
	var body string
	switch {
	case !there:
		body = "The workspace that work was in is gone (deleted, or you left it), so there is nothing to open. Ask me again and I will start it afresh."
		card = brainCard{}
	case !finished:
		body = "That is still going in your workspace: it is taking a while. Open it to see where it has got to."
		card.Subtitle = "Still working"
	case res.Status == "done" && strings.TrimSpace(res.Reply) != "":
		body = "Done. " + clip(strings.TrimSpace(res.Reply), jobReplyAt)
		card.Subtitle = "Finished: open for the files and details"
	case res.Status == "done":
		body = "Done: the work in your workspace has finished. Open it to see what was made."
		card.Subtitle = "Finished"
	default:
		why := strings.TrimSpace(res.Error)
		if why == "" {
			why = "it was stopped"
		}
		body = "The work in your workspace couldn't be finished: " + clip(why, 300)
		card.Subtitle = "Open to see what happened"
	}
	var cards []brainCard
	if card.Type != "" {
		cards = []brainCard{card}
	}
	s.storeAnswer(context.WithoutCancel(ctx), me, me, rec, j.Note, body, encodeProposal(nil, cards))
	// The admin's AI log: the work asked for, how long it took, and what Aseman wrote back.
	logged := aiEntry{person: me, kind: aiKindAseman, plan: "work", tools: []string{"work_on_it"}, prompt: s.jobRequest(j), answer: body, status: aiOK, started: j.CreatedAt}
	if !there || (finished && res.Status != "done") {
		logged.status, logged.err = aiError, errs.New(errs.CodeUnavailable, firstNonEmpty(res.Error, "the work could not be finished"))
	}
	s.logAI(context.WithoutCancel(ctx), logged)
	s.Push(ctx, []identity.ID{me}, PushNote{Title: "Aseman", Body: clip(body, 140), Kind: "dm", Peer: me.String(), Collapse: "job:" + j.ID})
}

var jobsOnce sync.Once

// startJobs delivers finished work, for as long as the node runs.
func (s *Service) startJobs() {
	jobsOnce.Do(func() {
		go func() {
			tick := time.NewTicker(jobEvery)
			defer tick.Stop()
			for now := range tick.C {
				s.deliverJobs(context.Background(), now.UTC())
			}
		}()
	})
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

// jobRequest is what the person asked the workspace to do (it is kept sealed).
func (s *Service) jobRequest(j brainJob) string {
	plain, err := crypto.OpenSecret(j.Request, s.K.Env()["node_private_key"], jobContext(j.ID))
	if err != nil {
		return ""
	}
	return plain
}

// jobsBrief tells Aseman what work it has handed to the person's workspace lately, so it can answer "is it done?"
// and knows it will write in the notes by itself when it is.
func (s *Service) jobsBrief(ctx context.Context, me identity.ID) string {
	var jobs []brainJob
	if err := s.R.List(ctx, "brain_jobs", database.Filter{Equal: map[string]any{"person": me.String()}, OrderBy: "created_at", Asc: false, Limit: 4}, &jobs); err != nil || len(jobs) == 0 {
		return ""
	}
	var b strings.Builder
	for _, j := range jobs {
		if time.Since(j.CreatedAt) > 6*time.Hour {
			continue
		}
		state := "still running in their workspace: when it finishes you write the result in these notes by yourself, with a card to open the workspace (they do not need to ask or check)"
		if j.Status == jobDone {
			state = "finished, and you already wrote the result in these notes"
		}
		b.WriteString("- Work you handed to their workspace at " + j.CreatedAt.Format("15:04") + " (" + state + "): " + clip(s.jobRequest(j), 160) + "\n")
	}
	if b.Len() == 0 {
		return ""
	}
	return "\n\n<your_work>\n" + b.String() + "</your_work>"
}

// answeringNote is the note in the person's own notes their Aseman is
// answering now (the newest, when more than one), or "".
func answeringNote(me identity.ID) string {
	savedAsks.Lock()
	defer savedAsks.Unlock()
	self, note, at := convKey(me, me), "", time.Time{}
	for _, a := range savedAsks.by[me] {
		if a.conv == self && a.since.After(at) {
			note, at = a.note, a.since
		}
	}
	return note
}

// answerCards are cards waiting for the answer to a note (what its work
// started), stored with that answer (see takeAnswerCards).
var answerCards = struct {
	sync.Mutex
	by map[string][]brainCard
}{by: map[string][]brainCard{}}

func addAnswerCard(note string, c brainCard) {
	if note == "" {
		return
	}
	answerCards.Lock()
	defer answerCards.Unlock()
	answerCards.by[note] = append(answerCards.by[note], c)
}

func takeAnswerCards(note string) []brainCard {
	answerCards.Lock()
	defer answerCards.Unlock()
	out := answerCards.by[note]
	delete(answerCards.by, note)
	return out
}

// brainWorkAction users.brain_work: the person's Aseman hands work to their
// own workspace (its lead and team, on the person's computer) and, when the
// team has finished, writes what came of it into the person's notes as an
// answer to the note it was asked in. Only the person (their Aseman acts as
// them) starts their work.
func brainWorkAction(s *Service) api.Action {
	return helper.Action{Namespace: "users", Name: "brain_work", Summary: "Hand work to your own workspace's team; the result is written in your Aseman chat when it is done",
		Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireUser(req); err != nil {
				return nil, err
			}
			var in struct {
				Request string `json:"request"`
			}
			if err := helper.Decode(req, &in); err != nil {
				return nil, err
			}
			request := strings.TrimSpace(in.Request)
			if request == "" {
				return nil, errs.InvalidArgument("say what the work is")
			}
			me := req.Caller.ID
			start, err := s.startWork(ctx, me, request)
			if err != nil {
				return nil, err
			}
			note := answeringNote(me)
			if err := s.addJob(ctx, me, start, request, note); err != nil {
				return nil, err
			}
			addAnswerCard(note, brainCard{Type: cardRoom, ID: start.SpaceID, Title: start.Name, Subtitle: "Working on it: I'll tell you here when it's done"})
			return helper.JSON(map[string]any{"ok": true, "space_id": start.SpaceID, "name": start.Name, "turn_id": start.TurnID,
				"note": "Started in " + start.Name + ". The result is written in the person's Aseman chat when the team finishes; say so."})
		}}
}
