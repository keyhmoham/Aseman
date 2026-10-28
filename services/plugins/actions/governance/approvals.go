package governance

import (
	"context"
	"fmt"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"strings"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/agui"
	"github.com/aseman/aseman/pkg/errs"
	gov "github.com/aseman/aseman/plugins/actions/governance/models"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// ask holds an action until a person answers: Allow once, Always allow, or
// Refuse. The card shows the exact action and the rule that asked; for a
// message, who it goes to and what it says. An action nobody answers before
// the timeout is refused.
func (s *Service) ask(ctx context.Context, req gate.Request, rule string) (gate.Result, error) {
	id, err := s.newID()
	if err != nil {
		return gate.Result{Decision: gov.DecisionDenied, Reason: "the approval could not be created"}, err
	}
	now := s.now().UTC()
	a := &gov.Approval{
		Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		Status: gov.ApprovalPending, Tool: req.Tool, Kind: req.Kind, Effect: req.Effect, Target: clip(Target(req), 300),
		Summary: clip(summarize(req), 600), Recipients: req.Recipients, Text: clip(req.Text, 4000), Rule: rule, Args: redactArgs(req),
		SpaceID: req.SpaceID, RoomID: req.RoomID, AgentID: req.AgentID, AgentName: req.AgentName, ActorID: req.ActorID,
		Initiator: firstNonEmpty(req.InitiatorKind, "person"), RunID: req.RunID, ExpiresAt: now.Add(s.ApprovalTimeout),
	}
	if err := s.R.CreateID(ctx, "approvals", id, a); err != nil {
		return gate.Result{Decision: gov.DecisionDenied, Reason: "the approval could not be created"}, err
	}
	asked := s.row(req, gov.DecisionAsked, rule)
	asked.ApprovalID = id.String()
	if err := s.writeAudit(ctx, asked); err != nil {
		return gate.Result{Decision: gov.DecisionDenied, Reason: "the action could not be recorded"}, err
	}
	s.announce(ctx, req, a)

	woke, done := s.waitFor(id.String())
	defer done()
	for {
		var cur gov.Approval
		if err := s.R.Get(ctx, "approvals", id, &cur); err != nil {
			return s.refuse(ctx, req, gov.DecisionDenied, rule, "the approval was lost")
		}
		switch cur.Status {
		case gov.ApprovalApproved:
			return s.allow(ctx, req, gov.DecisionApproved, rule, id.String())
		case gov.ApprovalRefused:
			return s.refuse(ctx, req, gov.DecisionRefused, rule, refusedBy(cur))
		case gov.ApprovalExpired, gov.ApprovalCanceled:
			return s.refuse(ctx, req, gov.DecisionTimedOut, rule, "nobody answered the approval in time; the action was not taken")
		}
		if !s.now().Before(cur.ExpiresAt) {
			s.settle(context.WithoutCancel(ctx), id, gov.ApprovalExpired, "", "")
			return s.refuse(ctx, req, gov.DecisionTimedOut, rule, "nobody answered the approval in time; the action was not taken")
		}
		if err := s.sleep(ctx, woke, cur.ExpiresAt); err != nil {
			s.settle(context.WithoutCancel(ctx), id, gov.ApprovalCanceled, "", "")
			return s.refuse(context.WithoutCancel(ctx), req, gov.DecisionTimedOut, rule, "the run stopped while waiting for approval")
		}
	}
}

func refusedBy(a gov.Approval) string {
	return "a person refused this action (" + a.Summary + "). Do not retry it; ask what they want instead."
}

// announce posts the approval card in the room and tells the person.
func (s *Service) announce(ctx context.Context, req gate.Request, a *gov.Approval) {
	space, err := identity.Parse(req.SpaceID)
	if err != nil || s.Spaces == nil {
		return
	}
	room, _ := identity.Parse(req.RoomID)
	sender, _ := identity.Parse(req.AgentAccount)
	if sender.IsZero() {
		sender, _ = s.Spaces.AsemanAccount(ctx)
	}
	body, err := agui.FormatMessage("", agui.ApprovalSurface(a.ID.String(), a.Summary, a.Tool, a.Effect, a.Rule, a.Recipients, a.Text))
	if err == nil && !sender.IsZero() {
		if perr := s.Spaces.PostMessage(context.WithoutCancel(ctx), space, room, sender, body); perr != nil && s.L != nil {
			s.L.Warn("approval card not posted", "approval", a.ID.String(), "error", perr)
		}
	}
	// Slack, Teams and SMS, where the person linked them, offer the same
	// answers; a namespace that is not loaded is simply not told.
	if s.K != nil {
		note := gate.ApprovalNote{ID: a.ID.String(), ActorID: req.ActorID, SpaceID: req.SpaceID, RoomID: req.RoomID, AgentName: req.AgentName,
			Summary: a.Summary, Tool: a.Tool, Effect: a.Effect, Rule: a.Rule, Recipients: a.Recipients, Text: a.Text}
		_ = bridge.Invoke(context.WithoutCancel(ctx), s.K, "channels", "ApprovalAsked", []any{context.WithoutCancel(ctx), note})
	}
	if s.Users != nil {
		if actor, err := identity.Parse(req.ActorID); err == nil && s.isPerson(ctx, req.ActorID) {
			who := firstNonEmpty(req.AgentName, "An agent")
			s.Users.Push(context.WithoutCancel(ctx), []identity.ID{actor}, PushNote{
				Title: who + " is waiting for your approval", Body: clip(a.Summary, 180), Kind: "approval",
				Space: req.SpaceID, Room: req.RoomID, Collapse: "approval-" + a.ID.String(),
			})
		}
	}
}

// summarize is the one line a person reads on the card.
func summarize(req gate.Request) string {
	if req.Summary != "" {
		return req.Summary
	}
	who := firstNonEmpty(req.AgentName, "An agent")
	switch {
	case req.Kind == gate.KindSandbox:
		return who + " wants to run: " + clip(req.Command, 400)
	case len(req.Recipients) > 0 && req.Effect == gate.EffectSend:
		return fmt.Sprintf("%s wants to send a message to %s", who, strings.Join(req.Recipients, ", "))
	case req.Kind == gate.KindApp:
		return who + " wants to call " + req.App + " → " + req.Function
	case req.Kind == gate.KindMCP:
		return who + " wants to use " + req.MCPServer + " → " + req.MCPTool
	case req.Kind == gate.KindHost:
		return who + " wants to use your computer: " + req.Tool + " " + firstNonEmpty(req.Command, req.Path)
	}
	return who + " wants to " + strings.ReplaceAll(req.Tool, "_", " ") + firstNonEmpty(" "+Target(req))
}

// AnswerApproval records a person's answer. "always" also stores a grant so
// this agent may take this action on this target again without asking.
func (s *Service) AnswerApproval(ctx context.Context, caller identity.ID, id identity.ID, answer string) (*gov.Approval, error) {
	var a gov.Approval
	if err := s.R.Get(ctx, "approvals", id, &a); err != nil {
		return nil, err
	}
	if caller.String() != a.ActorID && !s.canManage(ctx, caller, a.SpaceID) {
		return nil, errs.Permission("only the person the agent works for, or the project's owner, answers this")
	}
	status := gov.ApprovalApproved
	switch answer {
	case gov.AnswerOnce, gov.AnswerAlways:
	case gov.AnswerRefuse:
		status = gov.ApprovalRefused
	default:
		return nil, errs.InvalidArgument("answer must be once, always or refuse")
	}
	if a.Status != gov.ApprovalPending {
		return nil, errs.Conflict("this approval was already " + a.Status)
	}
	changed, err := s.settle(ctx, id, status, answer, caller.String())
	if err != nil {
		return nil, err
	}
	if !changed {
		return nil, errs.Conflict("this approval was answered already")
	}
	if answer == gov.AnswerAlways {
		if err := s.grant(ctx, a, caller); err != nil && s.L != nil {
			s.L.Warn("standing grant not stored", "approval", id.String(), "error", err)
		}
	}
	_ = s.R.Get(ctx, "approvals", id, &a)
	return &a, nil
}

// settle moves a pending approval to its outcome, once.
func (s *Service) settle(ctx context.Context, id identity.ID, status, answer, by string) (bool, error) {
	var a gov.Approval
	if err := s.R.Get(ctx, "approvals", id, &a); err != nil {
		return false, err
	}
	if a.Status != gov.ApprovalPending {
		return false, nil
	}
	a.Status, a.Answer, a.AnsweredBy = status, answer, by
	a.AnsweredAt = s.now().UTC()
	a.UpdatedAt = a.AnsweredAt
	changed := true
	if err := s.R.RequireAtomicUpdates(); err == nil {
		var err error
		changed, err = s.R.CompareAndSwap(ctx, "approvals", id.String(), map[string]any{"status": gov.ApprovalPending}, &a)
		if err != nil {
			return false, err
		}
	} else {
		if err := s.R.Update(ctx, "approvals", id, &a); err != nil {
			return false, err
		}
	}
	if changed {
		s.wake(id.String())
	}
	return changed, nil
}

// grant stores an "always allow".
func (s *Service) grant(ctx context.Context, a gov.Approval, by identity.ID) error {
	id, err := s.newID()
	if err != nil {
		return err
	}
	now := s.now().UTC()
	g := &gov.Grant{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, AccountID: firstNonEmpty(a.ActorID, by.String()),
		SpaceID: a.SpaceID, AgentID: a.AgentID, AgentName: a.AgentName, Tool: a.Tool, Target: a.Target, Summary: a.Summary}
	if err := s.R.CreateID(ctx, "approval_grants", id, g); err != nil {
		return err
	}
	s.Event(ctx, "grant.created", a.SpaceID, by.String(), a.Tool+" "+a.Target)
	return nil
}

// granted finds a standing grant for this person, project, agent, tool and
// target. A grant without a target covers the tool on any target.
func (s *Service) granted(ctx context.Context, req gate.Request) (gov.Grant, bool) {
	if req.ActorID == "" || req.SpaceID == "" {
		return gov.Grant{}, false
	}
	var rows []gov.Grant
	if err := s.R.List(ctx, "approval_grants", database.Filter{Equal: map[string]any{
		"account_id": req.ActorID, "space_id": req.SpaceID, "tool": req.Tool}, Limit: 200}, &rows); err != nil {
		return gov.Grant{}, false
	}
	target := Target(req)
	for _, g := range rows {
		if g.AgentID != "" && g.AgentID != req.AgentID {
			continue
		}
		if g.Target == "" || g.Target == target {
			return g, true
		}
	}
	return gov.Grant{}, false
}

// Approvals lists the approvals a person may answer or has answered.
func (s *Service) Approvals(ctx context.Context, caller identity.ID, space, status string, limit int) ([]gov.Approval, error) {
	f := database.Filter{Equal: map[string]any{}, OrderBy: "created_at", Limit: limit}
	if status != "" {
		f.Equal["status"] = status
	}
	if space != "" {
		if !s.isMember(ctx, caller, space) && !s.isAdmin(ctx, caller) {
			return nil, errs.Permission("not a member of the project")
		}
		f.Equal["space_id"] = space
		if !s.canManage(ctx, caller, space) {
			f.Equal["actor_id"] = caller.String()
		}
	} else {
		f.Equal["actor_id"] = caller.String()
	}
	var rows []gov.Approval
	if err := s.R.List(ctx, "approvals", f, &rows); err != nil {
		return nil, err
	}
	now := s.now()
	for i := range rows {
		if rows[i].Status == gov.ApprovalPending && !now.Before(rows[i].ExpiresAt) {
			rows[i].Status = gov.ApprovalExpired
		}
	}
	return rows, nil
}
