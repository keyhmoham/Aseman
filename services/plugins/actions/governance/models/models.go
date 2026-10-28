// Package governance holds the records of the governance namespace: the
// policies agent actions are decided against, the audit trail of every
// decision, the approvals people answer, their standing grants, the secret
// vault, the project computers' egress policies and their handovers.
package governance

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// NodeScope is the scope of the node-wide policy; a project's policy is
// scoped by the project's id.
const NodeScope = "node"

// Policy is one scope's rules: CEL expressions over a gate request, evaluated
// deny, then ask, then allow.
type Policy struct {
	entity.Entity
	Scope     string   `db:"scope" json:"scope"`
	Deny      []string `db:"deny" json:"deny"`
	Ask       []string `db:"ask" json:"ask"`
	Allow     []string `db:"allow" json:"allow"`
	UpdatedBy string   `db:"updated_by" json:"updated_by,omitempty"`
	Version   int64    `db:"version" json:"version"`
}

// Decisions an audit row records.
const (
	DecisionAllowed  = "allowed"
	DecisionDenied   = "denied"
	DecisionAsked    = "asked"
	DecisionApproved = "approved"
	DecisionRefused  = "refused"
	DecisionTimedOut = "timed_out"
	DecisionFailed   = "failed"
	// DecisionEvent is a control event that is not a decision on an action:
	// a handover, a secret supplied, an export taken.
	DecisionEvent = "event"
)

// AuditEvent is one row of the trail: who, on whose behalf, started by what,
// did or tried what, and what was decided. Arguments are stored redacted.
type AuditEvent struct {
	entity.Entity
	Decision      string `db:"decision" json:"decision"`
	Rule          string `db:"rule" json:"rule,omitempty"`
	Event         string `db:"event" json:"event,omitempty"`
	Tool          string `db:"tool" json:"tool,omitempty"`
	Kind          string `db:"kind" json:"kind,omitempty"`
	Effect        string `db:"effect" json:"effect,omitempty"`
	Target        string `db:"target" json:"target,omitempty"`
	SpaceID       string `db:"space_id" json:"space_id,omitempty"`
	RoomID        string `db:"room_id" json:"room_id,omitempty"`
	AgentID       string `db:"agent_id" json:"agent_id,omitempty"`
	AgentName     string `db:"agent_name" json:"agent_name,omitempty"`
	ActorID       string `db:"actor_id" json:"actor_id,omitempty"`
	InitiatorKind string `db:"initiator_kind" json:"initiator_kind"`
	InitiatorID   string `db:"initiator_id" json:"initiator_id,omitempty"`
	RunID         string `db:"run_id" json:"run_id,omitempty"`
	ApprovalID    string `db:"approval_id" json:"approval_id,omitempty"`
	Args          string `db:"args" json:"args,omitempty"`
	Detail        string `db:"detail" json:"detail,omitempty"`
}

// Approval states.
const (
	ApprovalPending  = "pending"
	ApprovalApproved = "approved"
	ApprovalRefused  = "refused"
	ApprovalExpired  = "expired"
	ApprovalCanceled = "canceled"
)

// Answers a person gives an approval.
const (
	AnswerOnce   = "once"
	AnswerAlways = "always"
	AnswerRefuse = "refuse"
)

// Approval is an action waiting on a person: the exact action and the rule
// that asked.
type Approval struct {
	entity.Entity
	Status     string    `db:"status" json:"status"`
	Answer     string    `db:"answer" json:"answer,omitempty"`
	AnsweredBy string    `db:"answered_by" json:"answered_by,omitempty"`
	Tool       string    `db:"tool" json:"tool"`
	Kind       string    `db:"kind" json:"kind,omitempty"`
	Effect     string    `db:"effect" json:"effect"`
	Target     string    `db:"target" json:"target,omitempty"`
	Summary    string    `db:"summary" json:"summary"`
	Recipients []string  `db:"recipients" json:"recipients,omitempty"`
	Text       string    `db:"text" json:"text,omitempty"`
	Rule       string    `db:"rule" json:"rule"`
	Args       string    `db:"args" json:"args,omitempty"`
	SpaceID    string    `db:"space_id" json:"space_id"`
	RoomID     string    `db:"room_id" json:"room_id,omitempty"`
	AgentID    string    `db:"agent_id" json:"agent_id,omitempty"`
	AgentName  string    `db:"agent_name" json:"agent_name,omitempty"`
	ActorID    string    `db:"actor_id" json:"actor_id"`
	Initiator  string    `db:"initiator_kind" json:"initiator_kind"`
	RunID      string    `db:"run_id" json:"run_id,omitempty"`
	ExpiresAt  time.Time `db:"expires_at" json:"expires_at"`
	AnsweredAt time.Time `db:"answered_at" json:"answered_at,omitempty"`
}

// Grant is a standing "always allow" a person gave: this agent may take this
// tool on this target in this project without asking again.
type Grant struct {
	entity.Entity
	AccountID string `db:"account_id" json:"account_id"`
	SpaceID   string `db:"space_id" json:"space_id"`
	AgentID   string `db:"agent_id" json:"agent_id,omitempty"`
	AgentName string `db:"agent_name" json:"agent_name,omitempty"`
	Tool      string `db:"tool" json:"tool"`
	Target    string `db:"target" json:"target,omitempty"`
	Summary   string `db:"summary" json:"summary,omitempty"`
}

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model {
	return []database.Model{policies(), auditEvents(), approvals(), grants(), vaultSecrets(), secretRequests(), egressPolicies(), handovers()}
}

func base(fields ...database.Field) []database.Field {
	return append([]database.Field{f("id", database.KindString), f("created_at", database.KindTime), f("updated_at", database.KindTime)}, fields...)
}

func policies() database.Model {
	return database.Model{Name: "governance_policies", Table: "governance_policies", Fields: base(
		f("scope", database.KindString), f("deny", database.KindJSON), f("ask", database.KindJSON), f("allow", database.KindJSON),
		f("updated_by", database.KindString), f("version", database.KindInt64))}
}

func auditEvents() database.Model {
	return database.Model{Name: "audit_events", Table: "audit_events", Fields: base(
		f("decision", database.KindString), f("rule", database.KindString), f("event", database.KindString), f("tool", database.KindString),
		f("kind", database.KindString), f("effect", database.KindString), f("target", database.KindString),
		f("space_id", database.KindString), f("room_id", database.KindString), f("agent_id", database.KindString), f("agent_name", database.KindString),
		f("actor_id", database.KindString), f("initiator_kind", database.KindString), f("initiator_id", database.KindString),
		f("run_id", database.KindString), f("approval_id", database.KindString), f("args", database.KindString), f("detail", database.KindString))}
}

func approvals() database.Model {
	return database.Model{Name: "approvals", Table: "approvals", Fields: base(
		f("status", database.KindString), f("answer", database.KindString), f("answered_by", database.KindString),
		f("tool", database.KindString), f("kind", database.KindString), f("effect", database.KindString), f("target", database.KindString),
		f("summary", database.KindString), f("recipients", database.KindJSON), f("text", database.KindString), f("rule", database.KindString),
		f("args", database.KindString), f("space_id", database.KindString), f("room_id", database.KindString), f("agent_id", database.KindString),
		f("agent_name", database.KindString), f("actor_id", database.KindString), f("initiator_kind", database.KindString), f("run_id", database.KindString),
		f("expires_at", database.KindTime), f("answered_at", database.KindTime))}
}

func grants() database.Model {
	return database.Model{Name: "approval_grants", Table: "approval_grants", Fields: base(
		f("account_id", database.KindString), f("space_id", database.KindString), f("agent_id", database.KindString), f("agent_name", database.KindString),
		f("tool", database.KindString), f("target", database.KindString), f("summary", database.KindString))}
}
