package governance

import (
	"bytes"
	"context"
	"encoding/csv"
	"strconv"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	gov "github.com/aseman/aseman/plugins/actions/governance/models"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// AuditQuery filters the trail.
type AuditQuery struct {
	Space     string `json:"space,omitempty"`
	From      string `json:"from,omitempty"`
	To        string `json:"to,omitempty"`
	Decision  string `json:"decision,omitempty"`
	Initiator string `json:"initiator,omitempty"`
	// Unattended is "nobody watching": routines, responsibilities, background
	// research and hand-offs together.
	Unattended bool   `json:"unattended,omitempty"`
	Tool       string `json:"tool,omitempty"`
	Agent      string `json:"agent,omitempty"`
	Actor      string `json:"actor,omitempty"`
	Event      string `json:"event,omitempty"`
	Limit      int    `json:"limit,omitempty"`
	Offset     int    `json:"offset,omitempty"`
}

// exportCap is the most rows one export holds.
const exportCap = 5000

// filter is the query as a database filter, after checking the caller may
// read that much: a project's owner its trail, an administrator any.
func (s *Service) filter(ctx context.Context, caller identity.ID, q AuditQuery) (database.Filter, error) {
	f := database.Filter{Equal: map[string]any{}, In: map[string][]any{}, GreaterThan: map[string]any{}, LessThan: map[string]any{},
		OrderBy: "created_at"}
	if q.Space != "" {
		if !s.canManage(ctx, caller, q.Space) {
			return f, errNotAllowed
		}
		f.Equal["space_id"] = q.Space
	} else if !s.isAdmin(ctx, caller) {
		return f, errs.Permission("administrator required for the node's trail; name a project you own")
	}
	for field, v := range map[string]string{"decision": q.Decision, "initiator_kind": q.Initiator, "tool": q.Tool,
		"agent_id": q.Agent, "actor_id": q.Actor, "event": q.Event} {
		if v != "" {
			f.Equal[field] = v
		}
	}
	if q.Unattended {
		f.In["initiator_kind"] = []any{vmm.InitiatorRoutine, vmm.InitiatorResponsibility, vmm.InitiatorProactive, vmm.InitiatorHandoff}
	}
	for field, v := range map[string]string{"from": q.From, "to": q.To} {
		if v == "" {
			continue
		}
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			return f, errs.InvalidArgument(field + " must be an RFC 3339 time")
		}
		if field == "from" {
			f.GreaterThan["created_at"] = t.Add(-time.Nanosecond)
		} else {
			f.LessThan["created_at"] = t
		}
	}
	return f, nil
}

// Audit lists the trail, newest first.
func (s *Service) Audit(ctx context.Context, caller identity.ID, q AuditQuery) ([]gov.AuditEvent, int64, error) {
	f, err := s.filter(ctx, caller, q)
	if err != nil {
		return nil, 0, err
	}
	total, _ := s.R.Count(ctx, "audit_events", f)
	f.Limit, f.Offset = q.Limit, q.Offset
	if f.Limit <= 0 || f.Limit > 500 {
		f.Limit = 100
	}
	var rows []gov.AuditEvent
	if err := s.R.List(ctx, "audit_events", f, &rows); err != nil {
		return nil, 0, err
	}
	return rows, total, nil
}

// Export is the trail under a filter as RFC 4180 CSV: newest first, at most
// exportCap rows (truncated says so), the arguments as one JSON column, every
// cell a spreadsheet would read as a formula prefixed with a quote. The export
// is itself recorded.
func (s *Service) Export(ctx context.Context, caller identity.ID, q AuditQuery) (string, int, bool, error) {
	f, err := s.filter(ctx, caller, q)
	if err != nil {
		return "", 0, false, err
	}
	var rows []gov.AuditEvent
	for page := 0; len(rows) < exportCap; page++ {
		f.Limit, f.Offset = 500, page*500
		var batch []gov.AuditEvent
		if err := s.R.List(ctx, "audit_events", f, &batch); err != nil {
			return "", 0, false, err
		}
		rows = append(rows, batch...)
		if len(batch) < 500 {
			break
		}
	}
	truncated := false
	if len(rows) > exportCap {
		rows, truncated = rows[:exportCap], true
	} else if len(rows) == exportCap {
		more, _ := s.R.Count(ctx, "audit_events", f)
		truncated = more > exportCap
	}
	var buf bytes.Buffer
	w := csv.NewWriter(&buf)
	_ = w.Write([]string{"time", "decision", "event", "rule", "tool", "kind", "effect", "target", "project", "room", "agent", "agent_name",
		"actor", "initiator_kind", "initiator_id", "run", "approval", "detail", "args"})
	for _, r := range rows {
		_ = w.Write(cells(r.CreatedAt.UTC().Format(time.RFC3339Nano), r.Decision, r.Event, r.Rule, r.Tool, r.Kind, r.Effect, r.Target,
			r.SpaceID, r.RoomID, r.AgentID, r.AgentName, r.ActorID, r.InitiatorKind, r.InitiatorID, r.RunID, r.ApprovalID, r.Detail, r.Args))
	}
	w.Flush()
	raw := q
	raw.Limit, raw.Offset = 0, 0
	s.Event(ctx, "audit.exported", q.Space, caller.String(), strconv.Itoa(len(rows))+" rows; filter "+describe(raw))
	return buf.String(), len(rows), truncated, w.Error()
}

// cells neutralizes formula injection: a cell starting with = + - @ (or a tab
// or carriage return) opens as text, never as a formula.
func cells(values ...string) []string {
	out := make([]string, len(values))
	for i, v := range values {
		if v != "" && strings.ContainsRune("=+-@\t\r", rune(v[0])) {
			v = "'" + v
		}
		out[i] = v
	}
	return out
}

func describe(q AuditQuery) string {
	parts := []string{}
	add := func(k, v string) {
		if v != "" {
			parts = append(parts, k+"="+v)
		}
	}
	add("space", q.Space)
	add("from", q.From)
	add("to", q.To)
	add("decision", q.Decision)
	add("initiator", q.Initiator)
	add("tool", q.Tool)
	add("agent", q.Agent)
	add("actor", q.Actor)
	add("event", q.Event)
	if q.Unattended {
		parts = append(parts, "nobody_watching")
	}
	if len(parts) == 0 {
		return "none"
	}
	return strings.Join(parts, " ")
}
