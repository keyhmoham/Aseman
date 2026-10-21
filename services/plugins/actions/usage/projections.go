package usages

import (
	"context"
	"fmt"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	financial "github.com/aseman/aseman/plugins/actions/finance/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/usage/models"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"sort"
	"time"
)

// computerSessionGap is the longest pause between two computer-time charges of
// one session. The computer is charged about once a minute while awake, so a
// longer gap means it slept in between.
const computerSessionGap = 5 * time.Minute

func projectionActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "usage", Name: "projects", Summary: "Settled project usage including deleted projects", Handler: func(c context.Context, r *api.ActionRequest) (*api.ActionResponse, error) {
			return s.projects(c, r, false)
		}},
		helper.Action{Namespace: "usage", Name: "platform", Summary: "Admin platform settled usage", Handler: func(c context.Context, r *api.ActionRequest) (*api.ActionResponse, error) {
			return s.projects(c, r, true)
		}},
		helper.Action{Namespace: "usage", Name: "model_summary", Summary: "Project model token accounting", Handler: func(c context.Context, r *api.ActionRequest) (*api.ActionResponse, error) {
			return s.modelSummary(c, r, false)
		}},
		helper.Action{Namespace: "usage", Name: "model_platform", Summary: "Admin platform model token accounting", Handler: func(c context.Context, r *api.ActionRequest) (*api.ActionResponse, error) {
			return s.modelSummary(c, r, true)
		}},
	}
}
func number(v any) int64 {
	switch n := v.(type) {
	case float64:
		return int64(n)
	case int64:
		return n
	case int:
		return int64(n)
	}
	return 0
}
func (s *Service) settlements(ctx context.Context, caller identity.ID, spaceID string, admin bool) ([]financial.Record, error) {
	if admin {
		req := &api.ActionRequest{Caller: api.Caller{ID: caller, Kind: "user"}}
		if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
			return nil, e
		}
	} else if spaceID != "" {
		id, e := identity.Parse(spaceID)
		if e != nil {
			return nil, e
		}
		if e = helper.CheckSpaceAccess(ctx, s.R, caller, id, identity.ID{}, false); e != nil {
			return nil, e
		}
	}
	filter := database.Filter{Equal: map[string]any{"kind": "settlement", "status": "completed"}, OrderBy: "created_at", Asc: false}
	if !admin && spaceID == "" {
		filter.Equal["owner"] = caller.String()
	}
	var rows []financial.Record
	if e := s.R.List(ctx, "financial_records", filter, &rows); e != nil {
		return nil, e
	}
	out := []financial.Record{}
	for _, r := range rows {
		if spaceID == "" || r.Data["space_id"] == spaceID {
			out = append(out, r)
		}
	}
	return out, nil
}
func (s *Service) projects(ctx context.Context, req *api.ActionRequest, admin bool) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		Space        string    `json:"space"`
		Limit        int       `json:"limit"`
		Offset       int       `json:"offset"`
		EventsLimit  int       `json:"events_limit"`
		EventsOffset int       `json:"events_offset"`
		Since        time.Time `json:"since"`
		Until        time.Time `json:"until"`
	}
	_ = helper.Decode(req, &in)
	records, e := s.settlements(ctx, req.Caller.ID, in.Space, admin)
	if e != nil {
		return nil, e
	}
	type project struct {
		id, title, owner           string
		deleted                    bool
		spent, compute, llm, tools int64
		rows                       map[string]map[string]any
		turns                      []map[string]any
		at                         time.Time
	}
	byID := map[string]*project{}
	events := []map[string]any{}
	// The computer session each project's charges are being gathered into
	// (records arrive newest first, so a session grows backwards in time).
	type computerSession struct {
		start       time.Time
		turn, event map[string]any
	}
	sessions := map[string]*computerSession{}
	var spent, compute, llm, tools int64
	for _, r := range records {
		if !in.Since.IsZero() && r.CreatedAt.Before(in.Since) || !in.Until.IsZero() && r.CreatedAt.After(in.Until) {
			continue
		}
		id, _ := r.Data["space_id"].(string)
		if id == "" {
			continue
		}
		p := byID[id]
		if p == nil {
			title, _ := r.Data["space_name"].(string)
			p = &project{id: id, title: title, owner: r.Owner, rows: map[string]map[string]any{}, turns: []map[string]any{}, at: r.CreatedAt}
			var sp space.Space
			if id, e := identity.Parse(id); e == nil {
				if e = s.R.Get(ctx, "spaces", id, &sp); e == nil {
					p.title = sp.Name
					p.owner = sp.OwnerID.String()
				} else if errs.CodeOf(e) == errs.CodeNotFound {
					p.deleted = true
				}
			}
			if p.title == "" {
				p.title = "Deleted room"
			}
			byID[p.id] = p
		}
		// Usage is what the work was worth: what was charged, plus work that
		// cost nothing because it ran on the customer's own node (own_*).
		c := number(r.Data["compute_minor"]) + number(r.Data["own_compute_minor"])
		l := number(r.Data["llm_minor"]) + number(r.Data["own_llm_minor"])
		t := number(r.Data["tool_minor"]) + number(r.Data["own_tool_minor"])
		r.Amount += number(r.Data["own_minor"])
		p.spent += r.Amount
		p.compute += c
		p.llm += l
		p.tools += t
		spent += r.Amount
		compute += c
		llm += l
		tools += t
		botID, _ := r.Data["bot_id"].(string)
		agentName := botID
		var botRecord struct {
			Name string `db:"name"`
		}
		if botID != "" && s.R.GetString(ctx, "bots", botID, &botRecord) == nil {
			agentName = botRecord.Name
		}
		if agentName == "" {
			agentName = "Agent"
		}
		// What the agent itself cost: its time and its model tokens (a record
		// that is only the computer or a tool is not the agent's).
		if agentPart := r.Amount - c - t; agentPart > 0 {
			key := "agent:" + botID
			bucket := p.rows[key]
			if bucket == nil {
				bucket = map[string]any{"key": key, "bot_id": botID, "name": agentName, "kind": "agent", "charged": int64(0), "compute": int64(0), "llm": int64(0)}
				p.rows[key] = bucket
			}
			bucket["charged"] = number(bucket["charged"]) + agentPart
			bucket["llm"] = number(bucket["llm"]) + l
		}
		if t > 0 {
			key := "tool:" + botID
			b := p.rows[key]
			if b == nil {
				b = map[string]any{"key": key, "bot_id": botID, "name": agentName, "kind": "tool", "charged": int64(0), "compute": int64(0), "llm": int64(0)}
				p.rows[key] = b
			}
			b["charged"] = number(b["charged"]) + t
		}
		if c > 0 {
			b := p.rows["compute"]
			if b == nil {
				b = map[string]any{"key": "compute", "name": "Computer time", "kind": "compute", "charged": int64(0), "compute": int64(0), "llm": int64(0)}
				p.rows["compute"] = b
			}
			b["charged"] = number(b["charged"]) + c
			b["compute"] = number(b["compute"]) + c
		}
		caption, _ := r.Data["description"].(string)
		if c > 0 && c == r.Amount {
			// The computer is charged a minute at a time while it is awake. To
			// the person that is one thing: the time it was on. Charges that
			// follow one another are shown as one session, from its first
			// charge (started_at) to its last (created_at).
			agentName, caption = "Computer", "Computer time"
			if cur := sessions[id]; cur != nil && cur.start.Sub(r.CreatedAt) <= computerSessionGap {
				cur.start = r.CreatedAt
				for _, row := range []map[string]any{cur.turn, cur.event} {
					row["started_at"] = r.CreatedAt
					row["charged"] = number(row["charged"]) + r.Amount
				}
				cur.turn["compute"] = number(cur.turn["compute"]) + c
				continue
			}
			turn := map[string]any{"id": r.ID, "created_at": r.CreatedAt, "started_at": r.CreatedAt, "bot_id": botID, "bot_name": agentName, "charged": r.Amount, "compute": c, "tool": t, "llm": l, "description": caption}
			event := map[string]any{"id": r.ID, "space_id": id, "space_name": p.title, "created_at": r.CreatedAt, "started_at": r.CreatedAt, "bot_id": botID, "bot_name": agentName, "description": caption, "charged": r.Amount, "deleted": p.deleted}
			sessions[id] = &computerSession{start: r.CreatedAt, turn: turn, event: event}
			p.turns = append(p.turns, turn)
			events = append(events, event)
			continue
		}
		p.turns = append(p.turns, map[string]any{"id": r.ID, "created_at": r.CreatedAt, "bot_id": botID, "bot_name": agentName, "charged": r.Amount, "compute": c, "tool": t, "llm": l, "description": caption})
		events = append(events, map[string]any{"id": r.ID, "space_id": id, "space_name": p.title, "created_at": r.CreatedAt, "bot_id": botID, "bot_name": agentName, "description": caption, "charged": r.Amount, "deleted": p.deleted})
	}
	sorted := []*project{}
	for _, p := range byID {
		sorted = append(sorted, p)
	}
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].at.After(sorted[j].at) })
	out := []map[string]any{}
	for _, p := range sorted {
		buckets := []map[string]any{}
		for _, b := range p.rows {
			buckets = append(buckets, b)
		}
		sort.Slice(buckets, func(i, j int) bool { return number(buckets[i]["charged"]) > number(buckets[j]["charged"]) })
		out = append(out, map[string]any{"space_id": p.id, "name": p.title, "owner_id": p.owner, "deleted": p.deleted, "spent": p.spent, "compute": p.compute, "tools": p.tools, "agents": p.spent - p.compute - p.tools, "llm": p.llm, "buckets": buckets, "charges": p.turns})
	}
	total := len(out)
	if !admin {
		limit, offset := helper.Paging(in.Limit, in.Offset, 50, 500)
		if offset > len(out) {
			offset = len(out)
		}
		end := min(offset+limit, len(out))
		out = out[offset:end]
	}
	eventTotal := len(events)
	limit, offset := helper.Paging(in.EventsLimit, in.EventsOffset, 50, 500)
	if offset > len(events) {
		offset = len(events)
	}
	events = events[offset:min(offset+limit, len(events))]
	return helper.JSON(map[string]any{"projects": out, "total": total, "totals": map[string]any{"spent": spent, "compute": compute, "tools": tools, "agents": spent - compute - tools, "llm": llm, "project_count": total}, "events": events, "event_total": eventTotal})
}
func (s *Service) modelSummary(ctx context.Context, req *api.ActionRequest, admin bool) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		Space string `json:"space"`
	}
	_ = helper.Decode(req, &in)
	if admin {
		if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
			return nil, e
		}
	} else {
		sp, e := identity.Parse(in.Space)
		if e != nil {
			return nil, e
		}
		if e = s.canViewSpace(ctx, req.Caller.ID, sp); e != nil {
			return nil, e
		}
	}
	filter := database.Filter{}
	if !admin || in.Space != "" {
		// An admin may narrow the platform view to one project.
		filter.Equal = map[string]any{"space_id": in.Space}
	}
	var rows []usage.Usage
	if e := s.R.List(ctx, "usages", filter, &rows); e != nil {
		return nil, e
	}
	settled, e := s.settlements(ctx, req.Caller.ID, in.Space, admin)
	if e != nil {
		return nil, e
	}
	paid := map[string]bool{}
	for _, r := range settled {
		paid[fmt.Sprint(r.Data["run_id"])+"/"+fmt.Sprint(r.Data["bot_id"])] = true
	}
	byModel := map[string]map[string]any{}
	byProvider := map[string]map[string]any{}
	byAgent := map[string]map[string]any{}
	projects := map[string]bool{}
	var totalIn, totalOut, billedIn, billedOut int64
	for _, r := range rows {
		totalIn += r.TokensIn
		totalOut += r.TokensOut
		projects[r.SpaceID.String()] = true
		if paid[r.RequestID+"/"+r.BotID.String()] {
			billedIn += r.TokensIn
			billedOut += r.TokensOut
		}
		add := func(rows map[string]map[string]any, key string) {
			if key == "" {
				key = "unknown"
			}
			v := rows[key]
			if v == nil {
				v = map[string]any{"tokens_in": int64(0), "tokens_out": int64(0), "calls": int64(0)}
				rows[key] = v
			}
			v["tokens_in"] = number(v["tokens_in"]) + r.TokensIn
			v["tokens_out"] = number(v["tokens_out"]) + r.TokensOut
			v["calls"] = number(v["calls"]) + 1
		}
		add(byModel, r.Model)
		add(byProvider, r.Provider)
		add(byAgent, r.BotID.String())
	}
	return helper.JSON(map[string]any{"tokens_in": totalIn, "tokens_out": totalOut, "tokens": totalIn + totalOut, "billed_tokens_in": billedIn, "billed_tokens_out": billedOut, "unbilled_tokens_in": totalIn - billedIn, "unbilled_tokens_out": totalOut - billedOut, "calls": len(rows), "by_model": byModel, "by_provider": byProvider, "by_bot": byAgent, "project_count": len(projects)})
}
