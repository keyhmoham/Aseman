package governance

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	gov "github.com/aseman/aseman/plugins/actions/governance/models"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/actions/governance/models/scan"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Gate decides one action an agent is about to take. In order:
//
//  1. resolve what it is and who takes it, on whose behalf, started by what;
//  2. hold it while a person has taken over the project computer it needs;
//  3. refuse outbound arguments carrying credentials or card numbers;
//  4. evaluate the node's and the project's policies;
//  5. for an ask, let a standing grant through or wait on a person;
//  6. write the audit row, and only then let it run, with the person's
//     secrets put into its arguments.
//
// A refusal is a Result with Allowed false and a reason the agent is told.
// An error is returned only when the action cannot be decided at all, and is
// a refusal too: the gate fails closed.
func (s *Service) Gate(ctx context.Context, req gate.Request) (gate.Result, error) {
	req = s.resolve(ctx, req)
	if res, held := s.holdForHandover(ctx, req); held {
		return res, nil
	}
	if finding := s.inspectOutbound(req); finding != "" {
		return s.refuse(ctx, req, gov.DecisionDenied, "outbound check", finding)
	}
	if refusal := s.egressRefusal(ctx, req); refusal != "" {
		return s.refuse(ctx, req, gov.DecisionDenied, "network policy", refusal)
	}
	v, err := s.verdict(ctx, req)
	if err != nil {
		return s.refuse(ctx, req, gov.DecisionDenied, "policy unavailable", "the policy could not be evaluated: "+err.Error())
	}
	switch v.effect {
	case "deny":
		return s.refuse(ctx, req, gov.DecisionDenied, v.rule, "refused by policy rule "+v.rule)
	case "ask":
		if g, ok := s.granted(ctx, req); ok {
			return s.allow(ctx, req, gov.DecisionAllowed, "always allowed by "+g.AccountID, "")
		}
		return s.ask(ctx, req, v.rule)
	}
	return s.allow(ctx, req, gov.DecisionAllowed, v.rule, "")
}

// Finish records an allowed action that failed once forwarded.
func (s *Service) Finish(ctx context.Context, auditID, failure string) error {
	if auditID == "" || failure == "" {
		return nil
	}
	id, err := identity.Parse(auditID)
	if err != nil {
		return nil
	}
	var first gov.AuditEvent
	if err := s.R.Get(ctx, "audit_events", id, &first); err != nil {
		return nil
	}
	row := first
	row.Decision, row.Detail, row.Rule = gov.DecisionFailed, clip(failure, 1000), ""
	return s.writeAudit(context.WithoutCancel(ctx), &row)
}

// resolve completes a request from the run it belongs to and its arguments.
func (s *Service) resolve(ctx context.Context, req gate.Request) gate.Request {
	exec := vmm.ExecutionFrom(ctx)
	if req.InitiatorKind == "" {
		i := vmm.InitiatorFrom(ctx)
		req.InitiatorKind, req.InitiatorID = i.Kind, i.ID
	}
	if req.RunID == "" {
		req.RunID = exec.RunID
	}
	if req.ActorID == "" {
		req.ActorID = exec.ActorID
	}
	if req.ActorID == "" {
		if a := helper.Actor(ctx); !a.IsZero() {
			req.ActorID = a.String()
		}
	}
	if req.SpaceID == "" {
		req.SpaceID = exec.SpaceID
	}
	if req.RoomID == "" {
		req.RoomID = firstNonEmpty(exec.RoomID, vmm.RoomFrom(ctx))
	}
	if req.AgentID == "" {
		req.AgentID = exec.AgentID
	}
	req = Normalize(req)
	// A direct message to a person other than the one the agent works for
	// reaches somebody outside the conversation: it is a send.
	if req.Tool == "users.dm_send" {
		for _, to := range req.Recipients {
			if to != req.ActorID && s.isPerson(ctx, to) {
				req.Effect = gate.EffectSend
			}
		}
	}
	return req
}

// verdict evaluates the node's policy and the project's.
func (s *Service) verdict(ctx context.Context, req gate.Request) (verdict, error) {
	node, err := s.compiledPolicy(ctx, gov.NodeScope)
	if err != nil {
		return verdict{}, err
	}
	var project *compiled
	if req.SpaceID != "" {
		if project, err = s.compiledPolicy(ctx, req.SpaceID); err != nil {
			return verdict{}, err
		}
	}
	return decide(node, project, Vars(req)), nil
}

// allow writes the audit row and lets the action run with the person's
// secrets put in.
func (s *Service) allow(ctx context.Context, req gate.Request, decision, rule, approvalID string) (gate.Result, error) {
	args, command, secrets, err := s.substituteSecrets(ctx, req)
	if err != nil {
		return s.refuse(ctx, req, gov.DecisionDenied, "secret", err.Error())
	}
	// Reads that were simply allowed are many and change nothing: they are
	// recorded only when the node asks for it (ASEMAN_AUDIT_READS=1).
	if decision == gov.DecisionAllowed && req.Effect == gate.EffectRead && len(secrets) == 0 && os.Getenv("ASEMAN_AUDIT_READS") != "1" {
		return gate.Result{Allowed: true, Decision: decision, Rule: rule, Args: args, Command: command}, nil
	}
	row := s.row(req, decision, rule)
	row.ApprovalID = approvalID
	if len(secrets) > 0 {
		names := make([]string, 0, len(secrets))
		for n := range secrets {
			names = append(names, n)
		}
		row.Detail = "used secrets: " + strings.Join(names, ", ")
	}
	if err := s.writeAudit(ctx, row); err != nil {
		// No record, no action.
		return gate.Result{Decision: gov.DecisionDenied, Reason: "the action could not be recorded"}, errs.Wrap(errs.CodeUnavailable, err, "audit")
	}
	return gate.Result{Allowed: true, Decision: decision, Rule: rule, AuditID: row.ID.String(), ApprovalID: approvalID,
		Args: args, Command: command, Secrets: secrets}, nil
}

// refuse records a refusal and returns it.
func (s *Service) refuse(ctx context.Context, req gate.Request, decision, rule, reason string) (gate.Result, error) {
	row := s.row(req, decision, rule)
	row.Detail = clip(reason, 1000)
	if err := s.writeAudit(context.WithoutCancel(ctx), row); err != nil && s.L != nil {
		s.L.Warn("refusal not recorded", "tool", req.Tool, "error", err)
	}
	return gate.Result{Decision: decision, Rule: rule, Reason: reason, AuditID: row.ID.String()}, nil
}

// row is the audit record of a request.
func (s *Service) row(req gate.Request, decision, rule string) *gov.AuditEvent {
	return &gov.AuditEvent{
		Decision: decision, Rule: clip(rule, 500), Tool: req.Tool, Kind: req.Kind, Effect: req.Effect, Target: clip(Target(req), 300),
		SpaceID: req.SpaceID, RoomID: req.RoomID, AgentID: req.AgentID, AgentName: req.AgentName, ActorID: req.ActorID,
		InitiatorKind: firstNonEmpty(req.InitiatorKind, vmm.InitiatorPerson), InitiatorID: req.InitiatorID, RunID: req.RunID,
		Args: redactArgs(req),
	}
}

// writeAudit stores one row.
func (s *Service) writeAudit(ctx context.Context, row *gov.AuditEvent) error {
	id, err := s.newID()
	if err != nil {
		return err
	}
	now := s.now().UTC()
	row.Entity = entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}
	if row.InitiatorKind == "" {
		row.InitiatorKind = vmm.InitiatorPerson
	}
	return s.R.CreateID(ctx, "audit_events", id, row)
}

// Event records a control event (a handover, a secret supplied, an export)
// that is not a decision on an action.
func (s *Service) Event(ctx context.Context, event, spaceID, actorID, detail string) {
	i := vmm.InitiatorFrom(ctx)
	row := &gov.AuditEvent{Decision: gov.DecisionEvent, Event: event, SpaceID: spaceID, ActorID: actorID, Detail: clip(detail, 1000),
		InitiatorKind: i.Kind, InitiatorID: i.ID}
	if err := s.writeAudit(context.WithoutCancel(ctx), row); err != nil && s.L != nil {
		s.L.Warn("event not recorded", "event", event, "error", err)
	}
}

// compiledPolicy is a scope's policy, compiled, cached briefly.
func (s *Service) compiledPolicy(ctx context.Context, scope string) (*compiled, error) {
	s.mu.Lock()
	cached, ok := s.policies[scope]
	s.mu.Unlock()
	if ok && s.now().Sub(cached.loaded) < policyTTL {
		return cached.c, nil
	}
	p, present, err := s.loadPolicy(ctx, scope)
	if err != nil {
		return nil, err
	}
	c, err := Compile(p)
	if err != nil {
		// A stored policy that no longer compiles must not fall open.
		return nil, err
	}
	s.mu.Lock()
	s.policies[scope] = cachedPolicy{c: c, loaded: s.now(), present: present}
	s.mu.Unlock()
	return c, nil
}

// loadPolicy reads a scope's stored policy, or its default.
func (s *Service) loadPolicy(ctx context.Context, scope string) (gov.Policy, bool, error) {
	var rows []gov.Policy
	if err := s.R.List(ctx, "governance_policies", database.Filter{Equal: map[string]any{"scope": scope}, Limit: 1}, &rows); err != nil {
		return gov.Policy{}, false, err
	}
	if len(rows) > 0 {
		return rows[0], true, nil
	}
	if scope == gov.NodeScope {
		return DefaultPolicy(), false, nil
	}
	return ProjectDefault(scope), false, nil
}

// SavePolicy validates and stores a scope's policy.
func (s *Service) SavePolicy(ctx context.Context, p gov.Policy, by string) (*gov.Policy, error) {
	if p.Deny == nil {
		p.Deny = []string{}
	}
	if p.Ask == nil {
		p.Ask = []string{}
	}
	if p.Allow == nil {
		p.Allow = []string{}
	}
	if _, err := Compile(p); err != nil {
		return nil, errs.InvalidArgument(err.Error())
	}
	old, present, err := s.loadPolicy(ctx, p.Scope)
	if err != nil {
		return nil, err
	}
	now := s.now().UTC()
	p.UpdatedBy = by
	if present {
		p.Entity = old.Entity
		p.Version = old.Version + 1
		p.UpdatedAt = now
		if err := s.R.Update(ctx, "governance_policies", p.ID, &p); err != nil {
			return nil, err
		}
	} else {
		id, err := s.newID()
		if err != nil {
			return nil, err
		}
		p.Entity = entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}
		p.Version = 1
		if err := s.R.CreateID(ctx, "governance_policies", id, &p); err != nil {
			return nil, err
		}
	}
	s.mu.Lock()
	delete(s.policies, p.Scope)
	s.mu.Unlock()
	raw, _ := json.Marshal(map[string]any{"deny": p.Deny, "ask": p.Ask, "allow": p.Allow, "version": p.Version})
	space := ""
	if p.Scope != gov.NodeScope {
		space = p.Scope
	}
	s.Event(ctx, "policy.changed", space, by, string(raw))
	return &p, nil
}

// DryRun decides a request against the current policies without recording,
// waiting or running anything.
func (s *Service) DryRun(ctx context.Context, req gate.Request) (map[string]any, error) {
	req = s.resolve(ctx, req)
	v, err := s.verdict(ctx, req)
	if err != nil {
		return nil, err
	}
	out := map[string]any{"decision": firstNonEmpty(v.effect, "deny"), "rule": v.rule, "effect": req.Effect, "kind": req.Kind,
		"target": Target(req), "variables": Vars(req)}
	if f := s.inspectOutbound(req); f != "" {
		out["decision"], out["rule"], out["finding"] = "deny", "outbound check", f
	}
	return out, nil
}

// redactArgs is what the trail keeps of an action's arguments: credentials
// and secret placeholders' values never, and at most 4,000 characters.
func redactArgs(req gate.Request) string {
	var v any = map[string]any{}
	if len(req.Args) > 0 {
		if d := decodeJSON(req.Args); d != nil {
			v = d
		}
	}
	if req.Command != "" {
		if m, ok := v.(map[string]any); ok {
			m["command"] = req.Command
		}
	}
	raw, _ := json.Marshal(helper.RedactCredentials(v))
	return clip(scan.Redact(string(raw)), 4000)
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func firstNonEmpty(v ...string) string {
	for _, s := range v {
		if strings.TrimSpace(s) != "" {
			return s
		}
	}
	return ""
}

// waitFor wakes when the record with this id changes on this node.
func (s *Service) waitFor(id string) (<-chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	s.mu.Lock()
	s.waiters[id] = append(s.waiters[id], ch)
	s.mu.Unlock()
	return ch, func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		list := s.waiters[id]
		for i, c := range list {
			if c == ch {
				s.waiters[id] = append(list[:i], list[i+1:]...)
				break
			}
		}
		if len(s.waiters[id]) == 0 {
			delete(s.waiters, id)
		}
	}
}

// wake tells this node's waiters a record changed.
func (s *Service) wake(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, ch := range s.waiters[id] {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

// sleep waits for a wake, the poll interval, or the context.
func (s *Service) sleep(ctx context.Context, woke <-chan struct{}, until time.Time) error {
	d := s.pollEvery
	if left := time.Until(until); left < d {
		d = left
	}
	if d <= 0 {
		return nil
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-woke:
	case <-t.C:
	}
	return nil
}
