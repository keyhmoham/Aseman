package spaces

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	"github.com/tradera/tradera/plugins/actions/spaces/models/permission"
	"github.com/tradera/tradera/plugins/actions/spaces/models/turn"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/actions/usage/models"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
	"strings"
	"sync"
	"time"
)

// SubmitRoomTurn persists message and executable intent in one provider-neutral
// transaction. Repeated submission IDs return the original accepted intent.
func (s *Service) SubmitRoomTurn(ctx context.Context, actor, spaceID, roomID identity.ID, submission, body, prompt string, seeds, attachments []string, silent bool) (*turn.Turn, error) {
	if err := s.Can(ctx, spaceID, roomID, actor, permission.RoomSend); err != nil {
		return nil, err
	}
	room, err := s.GetRoom(ctx, roomID)
	if err != nil {
		return nil, err
	}
	if room.SpaceID != spaceID {
		return nil, errs.InvalidArgument("room belongs to another space")
	}
	if strings.TrimSpace(prompt) == "" {
		prompt = body
	}
	if clean, noSandbox, noMemory := vmm.ParsePromptMode(prompt); (noSandbox || noMemory) && clean == "" && len(attachments) == 0 {
		return nil, errs.InvalidArgument("write a request after the command")
	}
	if strings.TrimSpace(body) == "" && len(attachments) == 0 && !silent {
		return nil, errs.InvalidArgument("message or attachment required")
	}
	if silent && strings.TrimSpace(prompt) == "" {
		return nil, errs.InvalidArgument("prompt required")
	}
	for _, ref := range attachments {
		id, e := identity.Parse(ref)
		if e != nil {
			return nil, e
		}
		if e = s.CanReadFile(ctx, id, actor); e != nil {
			return nil, e
		}
	}
	unique := []string{}
	seen := map[string]bool{}
	for _, ref := range seeds {
		b, e := s.findAgent(ctx, spaceID, ref)
		if e != nil {
			return nil, e
		}
		if seen[b.ID.String()] {
			continue
		}
		seen[b.ID.String()] = true
		unique = append(unique, b.ID.String())
		if e = s.Bots.EnsureFunds(vmm.WithExecution(ctx, vmm.Execution{ActorID: actor.String(), SpaceID: spaceID.String(), RoomID: roomID.String(), AgentID: b.ID.String()}), actor, b.ID); e != nil {
			return nil, e
		}
	}
	if submission == "" {
		id, e := identity.New(s.K.NodeID())
		if e != nil {
			return nil, e
		}
		submission = id.String()
	}
	if len(submission) > 160 {
		return nil, errs.InvalidArgument("submission id is too long")
	}
	id, err := identity.Parse(s.K.NodeID().String() + repo.ExecutionKey(actor.String() + "/" + spaceID.String() + "/" + submission)[16:])
	if err != nil {
		return nil, err
	}
	fingerprint, _ := json.Marshal([]any{roomID.String(), body, prompt, unique, attachments, silent})
	digest := sha256.Sum256(fingerprint)
	now := time.Now().UTC()
	t := &turn.Turn{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, SpaceID: spaceID, RoomID: roomID, ActorID: actor, Submission: submission, Fingerprint: hex.EncodeToString(digest[:]), Prompt: prompt, Seeds: unique, Attachments: attachments, Status: "queued"}
	if len(unique) == 0 {
		t.Status = "done"
		t.EndedAt = now
	}
	if !silent {
		t.MessageID = id.String()
	}
	err = s.R.DB.Transaction(ctx, func(ctx context.Context, tx database.Tx) error {
		var old turn.Turn
		if e := tx.Get(ctx, "room_turns", id.String(), &old); e == nil {
			if old.Fingerprint != t.Fingerprint {
				return errs.Conflict("submission id was already used for a different turn")
			}
			*t = old
			return nil
		} else if errs.CodeOf(e) != errs.CodeNotFound {
			return e
		}
		if e := tx.Create(ctx, "room_turns", id.String(), t); e != nil {
			return e
		}
		if !silent {
			m := &message.Message{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, SpaceID: spaceID, RoomID: roomID, SenderID: actor, Body: body}
			m.SetMentions(unique)
			m.SetAttachments(attachments)
			return tx.Create(ctx, "messages", id.String(), m)
		}
		return nil
	})
	return t, err
}
func turnActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "spaces", Name: "turn_log", Summary: "Read accepted work diagnostics", Handler: s.turnLog},
		helper.Action{Namespace: "spaces", Name: "turn_submit", Summary: "Durably submit a room turn", Handler: s.turnSubmit},
		helper.Action{Namespace: "spaces", Name: "turn_list", Summary: "Read accepted room work", Handler: s.turnList},
		helper.Action{Namespace: "spaces", Name: "turn_cancel", Summary: "Cancel accepted room work", Handler: s.turnCancel},
		helper.Action{Namespace: "spaces", Name: "turn_resume", Summary: "Explicitly retry inspected interrupted work", Handler: s.turnResume},
	}
}
func (s *Service) turnSubmit(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		Space       string   `json:"space"`
		Room        string   `json:"room"`
		Submission  string   `json:"submission_id"`
		Body        string   `json:"body"`
		Prompt      string   `json:"prompt"`
		Seeds       []string `json:"seeds"`
		Attachments []string `json:"attachments"`
		Silent      bool     `json:"silent"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	sp, e := identity.Parse(in.Space)
	if e != nil {
		return nil, e
	}
	room, e := identity.Parse(in.Room)
	if e != nil {
		return nil, e
	}
	t, e := s.SubmitRoomTurn(ctx, req.Caller.ID, sp, room, in.Submission, in.Body, in.Prompt, in.Seeds, in.Attachments, in.Silent)
	if e != nil {
		return nil, e
	}
	return helper.JSON(t)
}
func (s *Service) turnList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space  string `json:"space"`
		Room   string `json:"room"`
		Limit  int    `json:"limit"`
		Offset int    `json:"offset"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	sp, e := identity.Parse(in.Space)
	if e != nil {
		return nil, e
	}
	var room identity.ID
	if in.Room != "" {
		room, e = identity.Parse(in.Room)
		if e != nil {
			return nil, e
		}
	}
	if e = s.Can(ctx, sp, room, req.Caller.ID, permission.RoomRead); e != nil {
		return nil, e
	}
	in.Limit, in.Offset = helper.Paging(in.Limit, in.Offset, 100, 500)
	eq := map[string]any{"space_id": sp.String()}
	if !room.IsZero() {
		eq["room_id"] = room.String()
	}
	var rows []turn.Turn
	if e = s.R.List(ctx, "room_turns", database.Filter{Equal: eq, OrderBy: "created_at", Asc: false, Limit: in.Limit, Offset: in.Offset}, &rows); e != nil {
		return nil, e
	}
	total, e := s.R.Count(ctx, "room_turns", database.Filter{Equal: eq})
	if e != nil {
		return nil, e
	}
	return helper.JSON(map[string]any{"turns": rows, "total": total})
}
func (s *Service) readManagedTurn(ctx context.Context, req *api.ActionRequest) (*turn.Turn, error) {
	var in struct {
		Turn string `json:"turn"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	id, e := identity.Parse(in.Turn)
	if e != nil {
		return nil, e
	}
	var t turn.Turn
	if e = s.R.Get(ctx, "room_turns", id, &t); e != nil {
		return nil, e
	}
	if e = helper.CheckResourceManager(helper.WithActor(ctx, req.Caller.ID), s.R, t.SpaceID, t.RoomID, t.ActorID, "room.send"); e != nil {
		return nil, e
	}
	return &t, nil
}
func (s *Service) turnCancel(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	t, e := s.readManagedTurn(ctx, req)
	if e != nil {
		return nil, e
	}
	if t.Status == "done" || t.Status == "failed" || t.Status == "cancelled" {
		return helper.JSON(t)
	}
	old := t.Status
	t.Status = "cancelled"
	t.EndedAt = time.Now().UTC()
	t.UpdatedAt = t.EndedAt
	changed, e := s.R.CompareAndSwap(ctx, "room_turns", t.ID.String(), map[string]any{"status": old}, t)
	if e != nil {
		return nil, e
	}
	if !changed {
		return nil, errs.Conflict("turn changed")
	}
	// The whole team stops: the turn's agents, the agents they brought in and
	// what they left running in the project computer. A worker on another
	// node sees the status within its lease renewal and stops there.
	s.stopRun(t.ID.String())
	return helper.JSON(t)
}
func (s *Service) turnResume(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	t, e := s.readManagedTurn(ctx, req)
	if e != nil {
		return nil, e
	}
	if t.Status != "blocked" {
		return nil, errs.Conflict("only inspected interrupted turns can resume")
	}
	var in struct {
		Verdict string `json:"verdict"`
	}
	_ = helper.Decode(req, &in)
	if in.Verdict != "not_executed" {
		return nil, errs.InvalidArgument("confirm not_executed after inspecting external effects")
	}
	t.Status = "queued"
	t.Error = ""
	t.UpdatedAt = time.Now().UTC()
	changed, e := s.R.CompareAndSwap(ctx, "room_turns", t.ID.String(), map[string]any{"status": "blocked"}, t)
	if e != nil {
		return nil, e
	}
	if !changed {
		return nil, errs.Conflict("turn changed")
	}
	return helper.JSON(t)
}

// RunTurns is owned/drained by the namespace lifecycle, never the HTTP request.
func (s *Service) RunTurns(ctx context.Context) {
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	slots := make(chan struct{}, 4)
	var workers sync.WaitGroup
	defer workers.Wait()
	var lastReap time.Time
	for {
		if time.Since(lastReap) >= 30*time.Second {
			lastReap = time.Now()
			s.reapIdleSandboxes(ctx)
		}
		var rows []turn.Turn
		if e := s.R.List(ctx, "room_turns", database.Filter{In: map[string][]any{"status": {"queued", "running"}}, OrderBy: "created_at", Asc: true, Limit: 100}, &rows); e == nil {
			for _, t := range rows {
				if t.Status == "running" {
					if t.LeaseUntil.Before(time.Now()) {
						old := t.LeaseUntil
						t.Status = "blocked"
						t.Error = "Execution interrupted; inspect the room and files before resuming."
						t.UpdatedAt = time.Now().UTC()
						_, _ = s.R.CompareAndSwap(ctx, "room_turns", t.ID.String(), map[string]any{"status": "running", "lease_until": old}, &t)
					}
					continue
				}
				select {
				case slots <- struct{}{}:
					workers.Add(1)
					go func(t turn.Turn) { defer workers.Done(); defer func() { <-slots }(); s.executeTurn(ctx, t) }(t)
				default:
				}
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
func (s *Service) executeTurn(parent context.Context, t turn.Turn) {
	// Serialize work in one room across workers/nodes. Another room remains free.
	lease, e := repo.ClaimExecution(parent, s.R, s.K.NodeID(), "room-turn/"+t.RoomID.String(), time.Minute)
	if e != nil {
		return
	}
	defer lease.Release(context.WithoutCancel(parent), s.R)
	t.Status = "running"
	t.StartedAt = time.Now().UTC()
	t.LeaseUntil = t.StartedAt.Add(time.Minute)
	t.UpdatedAt = t.StartedAt
	changed, e := s.R.CompareAndSwap(parent, "room_turns", t.ID.String(), map[string]any{"status": "queued"}, &t)
	if e != nil || !changed {
		return
	}
	ctx, cancel := context.WithTimeout(parent, 30*time.Minute)
	defer cancel()
	team := s.openRun(t.ID.String(), t.SpaceID, cancel)
	defer s.closeRun(t.ID.String(), team)
	stop := make(chan struct{})
	renewDone := make(chan struct{})
	go func() {
		defer close(renewDone)
		tick := time.NewTicker(15 * time.Second)
		defer tick.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ctx.Done():
				return
			case <-tick.C:
				var current turn.Turn
				if e := s.R.Get(ctx, "room_turns", t.ID, &current); e != nil || current.Status != "running" {
					// Stopped from another node (or gone): stop the team here.
					s.stopRun(t.ID.String())
					return
				}
				old := current.LeaseUntil
				current.LeaseUntil = time.Now().UTC().Add(time.Minute)
				changed, e := s.R.CompareAndSwap(ctx, "room_turns", t.ID.String(), map[string]any{"status": "running", "lease_until": old}, &current)
				if e != nil || !changed {
					cancel()
					return
				}
				if e = lease.Renew(ctx, s.R, time.Minute); e != nil {
					cancel()
					return
				}
			}
		}
	}()
	prompt, noSandbox, noMemory := vmm.ParsePromptMode(t.Prompt)
	msg := &message.Message{Entity: t.Entity, SpaceID: t.SpaceID, RoomID: t.RoomID, SenderID: t.ActorID, Body: prompt}
	msg.SetMentions(t.Seeds)
	msg.SetAttachments(t.Attachments)
	policy := vmm.Execution{ActorID: t.ActorID.String(), SpaceID: t.SpaceID.String(), RoomID: t.RoomID.String(), RunID: t.ID.String(), NoSandbox: noSandbox, NoMemory: noMemory}
	if noSandbox || noMemory {
		policy.RequestScope = t.ID.String()
	}
	execution := vmm.WithExecution(usage.WithRequestID(helper.WithActor(ctx, t.ActorID), t.ID.String()), policy)
	// What the person asked for authorises image/file output for this turn. It is
	// set here, from the submitted prompt, because the execution above already
	// names the actor, and deliverToAgent only derives intent when it does not.
	execution = vmm.WithRequestIntent(execution, prompt, make([]vmm.FileAttachment, len(t.Attachments)))
	// Where the turn's time goes is recorded on the turn (admin project log). The
	// wait in the queue came first; the rest is reported by the work itself.
	execution, tracer := vmm.WithTracer(execution)
	tracer.Add("queue", "waiting for a worker and the room", t.CreatedAt, t.StartedAt.Sub(t.CreatedAt))
	// Each agent turn bills the turn's actor itself (runAgentTurn).
	_, runErr := s.DeliverMentions(execution, t.SpaceID, t.RoomID, msg)
	// The turn is the team's: it runs, and can be stopped, until every agent
	// brought in on it is done too.
	team.waitTeam(ctx)
	close(stop)
	<-renewDone
	finishCtx := context.WithoutCancel(parent)
	var current turn.Turn
	if e = s.R.Get(finishCtx, "room_turns", t.ID, &current); e != nil {
		return
	}
	rawSpans := tracer.Spans()
	spans := make([]turn.Span, 0, len(rawSpans))
	for _, sp := range rawSpans {
		spans = append(spans, turn.Span{Name: sp.Name, Detail: sp.Detail, Start: sp.Start, Ms: sp.Ms})
	}
	if current.Status != "running" {
		// turn_cancel changes the row before it cancels this context. Preserve the
		// completed trace after the worker unwinds, without changing the cancelled
		// outcome or its original end time.
		if current.Status == "cancelled" && len(spans) > 0 {
			current.Spans = spans
			current.UpdatedAt = time.Now().UTC()
			_, _ = s.R.CompareAndSwap(finishCtx, "room_turns", t.ID.String(), map[string]any{"status": "cancelled"}, &current)
		}
		return
	}
	current.Status = "done"
	if runErr != nil {
		current.Status = "failed"
		current.Error = runErr.Error()
	}
	if parent.Err() != nil {
		current.Status = "blocked"
		current.Error = "Execution interrupted; inspect before retrying."
	}
	current.EndedAt = time.Now().UTC()
	current.UpdatedAt = current.EndedAt
	current.Spans = spans
	_, _ = s.R.CompareAndSwap(finishCtx, "room_turns", t.ID.String(), map[string]any{"status": "running"}, &current)
}
