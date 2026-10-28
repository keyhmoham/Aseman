package responsibilities

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	rm "github.com/aseman/aseman/plugins/actions/responsibilities/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

func (s *Service) actions() []api.Action {
	a := func(name, summary string, h func(context.Context, *api.ActionRequest) (*api.ActionResponse, error)) api.Action {
		return helper.Action{Namespace: "responsibilities", Name: name, Summary: summary, Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireUser(req); err != nil {
				return nil, err
			}
			return h(helper.WithActor(ctx, req.Caller.ID), req)
		}}
	}
	return []api.Action{
		a("create", "Give an agent a standing responsibility: an instruction run when an email, GitHub event, Slack message or webhook matches", s.create),
		a("list", "My responsibilities (in a project, or all)", s.list),
		a("pause", "Pause a responsibility", s.toggle(false)),
		a("resume", "Resume a responsibility", s.toggle(true)),
		a("delete", "Delete a responsibility", s.delete),
		a("test", "Fire a responsibility now with a sample event", s.test),
	}
}

func (s *Service) create(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in Input
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	r, extra, err := s.Create(ctx, req.Caller.ID, in)
	if err != nil {
		return nil, err
	}
	out := map[string]any{"responsibility": r}
	for k, v := range extra {
		out[k] = v
	}
	return helper.JSON(out)
}

func (s *Service) list(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space string `json:"space,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	rows, err := s.List(ctx, req.Caller.ID, in.Space)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"responsibilities": rows, "hook_path": HookPath})
}

type idBody struct {
	ID    string `json:"id"`
	Event string `json:"event,omitempty"`
}

func (s *Service) toggle(on bool) func(context.Context, *api.ActionRequest) (*api.ActionResponse, error) {
	return func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
		var in idBody
		if err := helper.Decode(req, &in); err != nil {
			return nil, err
		}
		r, err := s.SetEnabled(ctx, req.Caller.ID, in.ID, on)
		if err != nil {
			return nil, err
		}
		return helper.JSON(map[string]any{"responsibility": r})
	}
}

func (s *Service) delete(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in idBody
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if err := s.Delete(ctx, req.Caller.ID, in.ID); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

func (s *Service) test(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in idBody
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	r, err := s.get(ctx, req.Caller.ID, in.ID)
	if err != nil {
		return nil, err
	}
	event := in.Event
	if strings.TrimSpace(event) == "" {
		event = "A sample event, sent from the responsibility's Test button."
	}
	reply, err := s.Fire(ctx, r, "test", event)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"reply": reply})
}

// AvailableTools: an agent working for a person may give itself an email
// responsibility (webhook ones need a secret only the person should see).
func (s *Service) AvailableTools(ctx context.Context, actor, space string) ([]string, error) {
	id, err := identity.Parse(actor)
	if err != nil || !s.canWrite(ctx, id, space) {
		return []string{}, nil
	}
	return []string{"responsibility_create", "responsibility_list"}, nil
}

// AgentTool serves responsibility_create (email triggers) and
// responsibility_list.
func (s *Service) AgentTool(ctx context.Context, call gate.ToolCall) (string, error) {
	owner, err := identity.Parse(call.ActorID)
	if err != nil {
		return "", errs.Permission("responsibilities belong to a person")
	}
	switch call.Tool {
	case "responsibility_create":
		var in Input
		_ = json.Unmarshal([]byte(call.Args), &in)
		in.Space, in.Room, in.Trigger = call.SpaceID, call.RoomID, rm.TriggerEmail
		r, _, err := s.Create(ctx, owner, in)
		if err != nil {
			return "", err
		}
		return "Responsibility \"" + r.Name + "\" is on: it runs when new mail matches " + EmailQuery(r) + ".", nil
	case "responsibility_list":
		rows, err := s.List(ctx, owner, call.SpaceID)
		if err != nil {
			return "", err
		}
		if len(rows) == 0 {
			return "No responsibilities in this project.", nil
		}
		var b strings.Builder
		for _, r := range rows {
			b.WriteString("- " + r.Name + " (" + r.Trigger + ", enabled " + map[bool]string{true: "yes", false: "no"}[r.Enabled] + "): " + clip(r.Instruction, 200) + "\n")
		}
		return b.String(), nil
	}
	return "", errs.NotFound("tool " + call.Tool)
}
