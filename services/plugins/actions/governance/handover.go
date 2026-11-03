package governance

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/agui"
	"github.com/aseman/aseman/pkg/errs"
	gov "github.com/aseman/aseman/plugins/actions/governance/models"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Handing the project computer to a person. An agent that meets a login wall,
// a two-factor prompt or a "verify you are human" page asks for help; a person
// takes control in the live desktop, does what only they can, and hands back.
// While a person holds the computer the agents' actions on it wait for the
// handover instead of fighting them. Each step is an audit event:
// computer.help_requested, computer.control_taken, computer.control_released.
// Aseman never solves a bot check on anybody's behalf.

// computerTools are the actions that use the project computer.
var computerTools = map[string]bool{
	"sandbox_exec": true, "file_edit": true, "file_upload": true, "appui_create": true, "appui_publish": true,
	"proxy_create": true,
}

func touchesComputer(req gate.Request) bool {
	return req.Kind == gate.KindSandbox || computerTools[req.Tool]
}

// holdForHandover waits while a person controls the project computer. It
// returns held when the wait ended in a refusal.
func (s *Service) holdForHandover(ctx context.Context, req gate.Request) (gate.Result, bool) {
	if req.SpaceID == "" || !touchesComputer(req) {
		return gate.Result{}, false
	}
	h, ok := s.activeHandover(ctx, req.SpaceID)
	if !ok || h.Status != gov.HandoverControlled {
		return gate.Result{}, false
	}
	deadline := s.now().Add(s.HandoverWait)
	woke, done := s.waitFor("handover-" + req.SpaceID)
	defer done()
	for {
		if err := s.sleep(ctx, woke, deadline); err != nil {
			res, _ := s.refuse(context.WithoutCancel(ctx), req, gov.DecisionDenied, "handover", "the run stopped while a person held the computer")
			return res, true
		}
		h, ok = s.activeHandover(ctx, req.SpaceID)
		if !ok || h.Status != gov.HandoverControlled {
			return gate.Result{}, false
		}
		if !s.now().Before(deadline) {
			res, _ := s.refuse(ctx, req, gov.DecisionDenied, "handover",
				"a person is controlling the project computer; wait until they hand it back, then try again")
			return res, true
		}
	}
}

// activeHandover is the project's latest handover that is not released.
func (s *Service) activeHandover(ctx context.Context, space string) (gov.Handover, bool) {
	var rows []gov.Handover
	if err := s.R.List(ctx, "computer_handovers", database.Filter{Equal: map[string]any{"space_id": space},
		OrderBy: "created_at", Limit: 1}, &rows); err != nil || len(rows) == 0 {
		return gov.Handover{}, false
	}
	if rows[0].Status == gov.HandoverReleased {
		return rows[0], false
	}
	return rows[0], true
}

// ComputerHelpTool is the agents' computer_help tool: ask a person to take
// over, and wait until they hand back.
func (s *Service) ComputerHelpTool(ctx context.Context, call gate.ToolCall) (string, error) {
	var in struct {
		Reason string `json:"reason"`
		URL    string `json:"url"`
	}
	_ = json.Unmarshal([]byte(call.Args), &in)
	if strings.TrimSpace(in.Reason) == "" {
		return "", errs.InvalidArgument("computer_help needs a reason: what the person has to do (log in, pass a check, ...)")
	}
	h, ok := s.activeHandover(ctx, call.SpaceID)
	if !ok {
		id, err := s.newID()
		if err != nil {
			return "", err
		}
		now := s.now().UTC()
		h = gov.Handover{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, SpaceID: call.SpaceID, RoomID: call.RoomID,
			Status: gov.HandoverRequested, AgentID: call.AgentID, AgentName: call.AgentName, Reason: clip(in.Reason, 500), URL: clip(in.URL, 1000)}
		if err := s.R.CreateID(ctx, "computer_handovers", id, &h); err != nil {
			return "", err
		}
		s.Event(ctx, "computer.help_requested", call.SpaceID, call.ActorID, firstNonEmpty(call.AgentName, "agent")+": "+h.Reason+" "+h.URL)
		s.postCard(ctx, call, agui.HandoverSurface(id.String(), h.Reason, h.URL))
		s.pushActor(ctx, call, firstNonEmpty(call.AgentName, "An agent")+" needs your help on the computer", h.Reason, "handover", "handover-"+call.SpaceID)
	}
	deadline := s.now().Add(s.HandoverWait)
	woke, done := s.waitFor("handover-" + call.SpaceID)
	defer done()
	for {
		var cur gov.Handover
		if err := s.R.Get(ctx, "computer_handovers", h.ID, &cur); err != nil {
			return "", err
		}
		if cur.Status == gov.HandoverReleased {
			note := ""
			if cur.Note != "" {
				note = " Their note: " + cur.Note
			}
			return "The person took over the computer and handed it back." + note + " Look at the screen again before you go on.", nil
		}
		if !s.now().Before(deadline) {
			return "Nobody took over the computer in time. Tell the person what is blocked; do not try to get past the check yourself.", nil
		}
		if err := s.sleep(ctx, woke, deadline); err != nil {
			return "", err
		}
	}
}

// TakeControl gives the project computer to a person.
func (s *Service) TakeControl(ctx context.Context, caller identity.ID, space string) (*gov.Handover, error) {
	if !s.isMember(ctx, caller, space) {
		return nil, errs.Permission("not a member of the project")
	}
	now := s.now().UTC()
	h, ok := s.activeHandover(ctx, space)
	if ok && h.Status == gov.HandoverControlled && h.ControllerID != caller.String() {
		return nil, errs.Conflict("someone else has control of the computer")
	}
	if !ok {
		id, err := s.newID()
		if err != nil {
			return nil, err
		}
		h = gov.Handover{Entity: entity.Entity{ID: id, CreatedAt: now}, SpaceID: space}
	}
	h.Status, h.ControllerID, h.TakenAt, h.UpdatedAt = gov.HandoverControlled, caller.String(), now, now
	var err error
	if ok {
		err = s.R.Update(ctx, "computer_handovers", h.ID, &h)
	} else {
		err = s.R.CreateID(ctx, "computer_handovers", h.ID, &h)
	}
	if err != nil {
		return nil, err
	}
	s.Event(ctx, "computer.control_taken", space, caller.String(), h.Reason)
	s.wake("handover-" + space)
	return &h, nil
}

// ReleaseControl hands the project computer back to its agents.
func (s *Service) ReleaseControl(ctx context.Context, caller identity.ID, space, note string) (*gov.Handover, error) {
	h, ok := s.activeHandover(ctx, space)
	if !ok {
		return nil, errs.NotFound("nobody holds the computer")
	}
	if h.Status == gov.HandoverControlled && h.ControllerID != caller.String() && !s.canManage(ctx, caller, space) {
		return nil, errs.Permission("only the person in control, or the project's owner, hands it back")
	}
	if h.Status == gov.HandoverRequested && !s.isMember(ctx, caller, space) {
		return nil, errs.Permission("not a member of the project")
	}
	now := s.now().UTC()
	h.Status, h.ReleasedAt, h.UpdatedAt, h.Note = gov.HandoverReleased, now, now, clip(strings.TrimSpace(note), 500)
	if err := s.R.Update(ctx, "computer_handovers", h.ID, &h); err != nil {
		return nil, err
	}
	s.Event(ctx, "computer.control_released", space, caller.String(), h.Note)
	s.wake("handover-" + space)
	return &h, nil
}

// HandoverState is the project computer's current holder, for the client.
func (s *Service) HandoverState(ctx context.Context, caller identity.ID, space string) (map[string]any, error) {
	if !s.isMember(ctx, caller, space) {
		return nil, errs.Permission("not a member of the project")
	}
	h, ok := s.activeHandover(ctx, space)
	if !ok {
		return map[string]any{"status": "agents"}, nil
	}
	return map[string]any{"status": h.Status, "handover": h, "since": h.UpdatedAt.Format(time.RFC3339)}, nil
}
