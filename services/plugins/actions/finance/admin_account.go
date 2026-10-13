package finance

import (
	"context"
	"sort"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/finance/models"
	"github.com/tradera/tradera/plugins/actions/finance/models/wallet"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
)

// adminAccount is one person's money in full, for the admin: what they bought,
// what was added to their wallet by hand, what they spent (by part and by
// project) and the recent wallet movements. Amounts are ledger units.
func (s *Service) adminAccount(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var in struct {
		Account string `json:"account"`
		Limit   int    `json:"limit"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	id, e := identity.Parse(in.Account)
	if e != nil {
		return nil, e
	}
	if in.Limit <= 0 || in.Limit > 500 {
		in.Limit = 200
	}
	w, e := s.GetWallet(ctx, id)
	if e != nil {
		return nil, e
	}

	var records []models.Record
	if e := s.R.List(ctx, "financial_records", database.Filter{Equal: map[string]any{"owner": id.String()}}, &records); e != nil {
		return nil, e
	}
	var bought, reversed, boughtCount, spent, compute, tools, llm, agent int64
	type projectSpend struct {
		ID, Name string
		Amount   int64
	}
	projects := map[string]*projectSpend{}
	for _, r := range records {
		switch r.Kind {
		case "purchase":
			if sandbox, _ := r.Data["sandbox"].(bool); sandbox {
				continue
			}
			switch r.Status {
			case "completed":
				bought += r.Amount
				boughtCount++
			case "reversed":
				reversed += r.Amount
			}
		case "settlement":
			if r.Status != "completed" {
				continue
			}
			spent += r.Amount
			compute += amountOf(r.Data["compute_minor"])
			tools += amountOf(r.Data["tool_minor"])
			llm += amountOf(r.Data["llm_minor"])
			agent += amountOf(r.Data["agent_minor"])
			sid, _ := r.Data["space_id"].(string)
			name, _ := r.Data["space_name"].(string)
			p := projects[sid]
			if p == nil {
				p = &projectSpend{ID: sid, Name: name}
				projects[sid] = p
			}
			p.Amount += r.Amount
		}
	}

	var entries []wallet.LedgerEntry
	if e := s.R.List(ctx, "ledger", database.Filter{OrderBy: "created_at", Asc: false}, &entries); e != nil {
		return nil, e
	}
	var granted, earned int64
	moves := []map[string]any{}
	for _, l := range entries {
		if l.FromID != id && l.ToID != id {
			continue
		}
		if l.Type == wallet.EntryPoolLock || l.Type == wallet.EntryPoolFree {
			continue
		}
		change := l.Amount
		if l.FromID == id {
			change = -l.Amount
		}
		if l.Type == wallet.EntryMint && l.ToID == id && !hasPrefix(l.Description, "verified purchase") {
			granted += l.Amount
		}
		if l.ToID == id && (l.Type == wallet.EntryPayBot || l.Type == wallet.EntryPayNode || l.Type == wallet.EntryPayLLM) {
			earned += l.Amount
		}
		if len(moves) < in.Limit {
			moves = append(moves, map[string]any{"id": l.ID.String(), "type": l.Type, "amount": change, "description": l.Description, "created_at": l.CreatedAt})
		}
	}

	byProject := make([]map[string]any, 0, len(projects))
	list := make([]*projectSpend, 0, len(projects))
	for _, p := range projects {
		list = append(list, p)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Amount > list[j].Amount })
	for _, p := range list {
		byProject = append(byProject, map[string]any{"space_id": p.ID, "name": p.Name, "amount": p.Amount})
	}

	return helper.JSON(map[string]any{
		"balance": w.Balance, "locked": w.Locked,
		"bought": bought, "bought_count": boughtCount, "reversed": reversed,
		"granted": granted, "earned": earned,
		"spent": spent, "spent_by": map[string]any{"compute": compute, "tools": tools, "llm": llm, "agent": agent},
		"projects": byProject, "movements": moves,
	})
}

func hasPrefix(s, p string) bool { return len(s) >= len(p) && s[:len(p)] == p }
