package governance

import (
	"context"
	"encoding/json"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	gov "github.com/aseman/aseman/plugins/actions/governance/models"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// AgentTool serves the agent tools this namespace owns.
func (s *Service) AgentTool(ctx context.Context, call gate.ToolCall) (string, error) {
	switch call.Tool {
	case "secret_request":
		return s.SecretRequestTool(ctx, call)
	case "computer_help":
		return s.ComputerHelpTool(ctx, call)
	}
	return "", errs.NotFound("tool " + call.Tool)
}

// AvailableTools are this namespace's agent tools, offered everywhere.
func (s *Service) AvailableTools(ctx context.Context, actor, space string) ([]string, error) {
	return []string{"secret_request", "computer_help"}, nil
}

func (s *Service) actions() []api.Action {
	a := func(name, summary string, h func(context.Context, *api.ActionRequest) (*api.ActionResponse, error)) api.Action {
		return helper.Action{Namespace: "governance", Name: name, Summary: summary, Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireUser(req); err != nil {
				return nil, err
			}
			return h(helper.WithActor(ctx, req.Caller.ID), req)
		}}
	}
	return []api.Action{
		a("policy_get", "The node's policy, or a project's (space), with the variables rules may use", s.policyGet),
		a("policy_set", "Save the node's policy (administrator) or a project's (its owner): deny, ask and allow CEL rules", s.policySet),
		a("policy_test", "Dry run: how the current policies decide a sample action", s.policyTest),
		a("audit_list", "The audit trail of agent actions: the node's (administrator) or a project's (its owner)", s.auditList),
		a("audit_export", "The audit trail under a filter as CSV (at most 5,000 rows); the export is itself recorded", s.auditExport),
		a("approval_list", "Approvals waiting on me, or a project's", s.approvalList),
		a("approval_get", "One approval and its state", s.approvalGet),
		a("approval_answer", "Answer an approval: once, always or refuse", s.approvalAnswer),
		a("grant_list", "My standing \"always allow\" grants (or a project's, for its owner)", s.grantList),
		a("grant_revoke", "Revoke a standing grant", s.grantRevoke),
		a("secret_submit", "Fill a secret box: the value is sealed in the vault and never returned", s.secretSubmit),
		a("secret_decline", "Decline a secret box", s.secretDecline),
		a("secret_set", "Save a credential for a project's agents to use as {{secret:name}}", s.secretSet),
		a("secret_list", "A project's saved credentials: names and lengths, never values", s.secretList),
		a("secret_delete", "Delete a saved credential", s.secretDelete),
		a("egress_get", "Where a project's computer may connect", s.egressGet),
		a("egress_set", "Set where a project's computer may connect (its owner)", s.egressSet),
		a("control_state", "Who holds a project's computer: its agents, or a person", s.controlState),
		a("control_take", "Take control of a project's computer; its agents wait", s.controlTake),
		a("control_release", "Hand a project's computer back to its agents", s.controlRelease),
	}
}

type spaceBody struct {
	Space string `json:"space,omitempty"`
}

func (s *Service) policyGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in spaceBody
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	scope := gov.NodeScope
	if in.Space != "" {
		if !s.isMember(ctx, req.Caller.ID, in.Space) && !s.isAdmin(ctx, req.Caller.ID) {
			return nil, errs.Permission("not a member of the project")
		}
		scope = in.Space
	} else if !s.isAdmin(ctx, req.Caller.ID) {
		return nil, errs.Permission("administrator required")
	}
	p, present, err := s.loadPolicy(ctx, scope)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"policy": p, "default": !present, "defaults": DefaultPolicy(),
		"variables": []string{"tool.name", "tool.kind", "tool.effect", "agent.id", "agent.name", "actor.id", "initiator.kind", "initiator.id",
			"space.id", "room.id", "command", "file.path", "file.name", "file.extension", "url.full", "url.host", "app.slug", "app.function",
			"mcp.server", "mcp.tool", "recipients", "args"},
		"effects": []string{gate.EffectRead, gate.EffectWrite, gate.EffectSend, gate.EffectPay, gate.EffectSign, gate.EffectDelete, gate.EffectExternal}})
}

func (s *Service) policySet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space string   `json:"space,omitempty"`
		Deny  []string `json:"deny"`
		Ask   []string `json:"ask"`
		Allow []string `json:"allow"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	scope := gov.NodeScope
	if in.Space != "" {
		if !s.canManage(ctx, req.Caller.ID, in.Space) {
			return nil, errNotAllowed
		}
		scope = in.Space
	} else if !s.isAdmin(ctx, req.Caller.ID) {
		return nil, errs.Permission("administrator required")
	}
	p, err := s.SavePolicy(ctx, gov.Policy{Scope: scope, Deny: in.Deny, Ask: in.Ask, Allow: in.Allow}, req.Caller.ID.String())
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"policy": p})
}

func (s *Service) policyTest(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space   string       `json:"space,omitempty"`
		Request gate.Request `json:"request"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if in.Space != "" {
		if !s.canManage(ctx, req.Caller.ID, in.Space) {
			return nil, errNotAllowed
		}
		in.Request.SpaceID = in.Space
	} else if !s.isAdmin(ctx, req.Caller.ID) {
		return nil, errs.Permission("administrator required")
	}
	if in.Request.ActorID == "" {
		in.Request.ActorID = req.Caller.ID.String()
	}
	out, err := s.DryRun(ctx, in.Request)
	if err != nil {
		return nil, errs.InvalidArgument(err.Error())
	}
	return helper.JSON(out)
}

func (s *Service) auditList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var q AuditQuery
	if err := helper.Decode(req, &q); err != nil {
		return nil, err
	}
	rows, total, err := s.Audit(ctx, req.Caller.ID, q)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"events": rows, "total": total})
}

func (s *Service) auditExport(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var q AuditQuery
	if err := helper.Decode(req, &q); err != nil {
		return nil, err
	}
	text, n, truncated, err := s.Export(ctx, req.Caller.ID, q)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"csv": text, "rows": n, "truncated": truncated, "cap": exportCap,
		"filename": "aseman-audit.csv"})
}

func (s *Service) approvalList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space  string `json:"space,omitempty"`
		Status string `json:"status,omitempty"`
		Limit  int    `json:"limit,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if in.Limit <= 0 || in.Limit > 200 {
		in.Limit = 50
	}
	rows, err := s.Approvals(ctx, req.Caller.ID, in.Space, in.Status, in.Limit)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"approvals": rows})
}

func idOf(req *api.ActionRequest, field string) (identity.ID, error) {
	var in map[string]any
	if err := helper.Decode(req, &in); err != nil {
		return identity.ID{}, err
	}
	raw, _ := in[field].(string)
	id, err := identity.Parse(raw)
	if err != nil {
		return identity.ID{}, errs.InvalidArgument("invalid " + field)
	}
	return id, nil
}

func (s *Service) approvalGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	id, err := idOf(req, "id")
	if err != nil {
		return nil, err
	}
	var a gov.Approval
	if err := s.R.Get(ctx, "approvals", id, &a); err != nil {
		return nil, err
	}
	if a.ActorID != req.Caller.ID.String() && !s.isMember(ctx, req.Caller.ID, a.SpaceID) {
		return nil, errs.Permission("not a member of the project")
	}
	if a.Status == gov.ApprovalPending && !s.now().Before(a.ExpiresAt) {
		a.Status = gov.ApprovalExpired
	}
	canAnswer := a.ActorID == req.Caller.ID.String() || s.canManage(ctx, req.Caller.ID, a.SpaceID)
	return helper.JSON(map[string]any{"approval": a, "can_answer": canAnswer})
}

func (s *Service) approvalAnswer(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		ID     string `json:"id"`
		Answer string `json:"answer"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.ID)
	if err != nil {
		return nil, errs.InvalidArgument("invalid id")
	}
	a, err := s.AnswerApproval(ctx, req.Caller.ID, id, in.Answer)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"approval": a})
}

func (s *Service) grantList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in spaceBody
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	f := database.Filter{Equal: map[string]any{}, OrderBy: "created_at", Limit: 500}
	if in.Space != "" && s.canManage(ctx, req.Caller.ID, in.Space) {
		f.Equal["space_id"] = in.Space
	} else {
		f.Equal["account_id"] = req.Caller.ID.String()
		if in.Space != "" {
			f.Equal["space_id"] = in.Space
		}
	}
	var rows []gov.Grant
	if err := s.R.List(ctx, "approval_grants", f, &rows); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"grants": rows})
}

func (s *Service) grantRevoke(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	id, err := idOf(req, "id")
	if err != nil {
		return nil, err
	}
	var g gov.Grant
	if err := s.R.Get(ctx, "approval_grants", id, &g); err != nil {
		return nil, err
	}
	if g.AccountID != req.Caller.ID.String() && !s.canManage(ctx, req.Caller.ID, g.SpaceID) {
		return nil, errs.Permission("only the person who gave it, or the project's owner, revokes a grant")
	}
	if err := s.R.Delete(ctx, "approval_grants", id); err != nil {
		return nil, err
	}
	s.Event(ctx, "grant.revoked", g.SpaceID, req.Caller.ID.String(), g.Tool+" "+g.Target)
	return helper.JSON(map[string]any{"ok": true})
}

func (s *Service) secretSubmit(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Request string `json:"request"`
		Value   string `json:"value"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Request)
	if err != nil {
		return nil, errs.InvalidArgument("invalid request")
	}
	if err := s.AnswerSecret(ctx, req.Caller.ID, id, in.Value, false); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

func (s *Service) secretDecline(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	id, err := idOf(req, "request")
	if err != nil {
		return nil, err
	}
	if err := s.AnswerSecret(ctx, req.Caller.ID, id, "", true); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

func (s *Service) secretSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space string `json:"space"`
		Name  string `json:"name"`
		Site  string `json:"site,omitempty"`
		Value string `json:"value"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if !s.isMember(ctx, req.Caller.ID, in.Space) {
		return nil, errs.Permission("not a member of the project")
	}
	v, err := s.StoreSecret(ctx, req.Caller.ID, in.Space, in.Name, in.Site, in.Value)
	if err != nil {
		return nil, err
	}
	v.Sealed = ""
	return helper.JSON(map[string]any{"secret": v})
}

func (s *Service) secretList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in spaceBody
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	rows, err := s.Secrets(ctx, req.Caller.ID, in.Space)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"secrets": rows})
}

func (s *Service) secretDelete(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	id, err := idOf(req, "id")
	if err != nil {
		return nil, err
	}
	if err := s.DeleteSecret(ctx, req.Caller.ID, id); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

func (s *Service) egressGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in spaceBody
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if !s.isMember(ctx, req.Caller.ID, in.Space) && !s.isAdmin(ctx, req.Caller.ID) {
		return nil, errs.Permission("not a member of the project")
	}
	p, err := s.Egress(ctx, in.Space)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"policy": p, "can_edit": s.canManage(ctx, req.Caller.ID, in.Space)})
}

func (s *Service) egressSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space string   `json:"space"`
		Mode  string   `json:"mode"`
		Allow []string `json:"allow"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	p, err := s.SetEgress(ctx, req.Caller.ID, in.Space, in.Mode, in.Allow)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"policy": p})
}

func (s *Service) controlState(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in spaceBody
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	out, err := s.HandoverState(ctx, req.Caller.ID, in.Space)
	if err != nil {
		return nil, err
	}
	return helper.JSON(out)
}

func (s *Service) controlTake(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in spaceBody
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	h, err := s.TakeControl(ctx, req.Caller.ID, in.Space)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"handover": h})
}

func (s *Service) controlRelease(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space string `json:"space"`
		Note  string `json:"note,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	h, err := s.ReleaseControl(ctx, req.Caller.ID, in.Space, in.Note)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"handover": h})
}

func jsonStatus(status int, v any) *network.Response {
	raw, _ := json.Marshal(v)
	return &network.Response{Status: status, Header: map[string]string{"Content-Type": "application/json"}, Body: raw}
}
