package finance

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/finance/models"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

func amountOf(v any) int64 {
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

// overview is the platform's money in one page for a period (all amounts are
// ledger units): what was sold, what customers spent and on which part, where
// that spend went (creators vs the platform), and what users still hold.
//
// The node knows what customers were charged, not what the platform's own
// providers invoice (OpenAI, Modal, hosting): "kept" is therefore revenue
// before those bills, and the page says so.
func (s *Service) overview(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var in struct {
		Since time.Time `json:"since"`
		Until time.Time `json:"until"`
	}
	_ = helper.Decode(req, &in)
	within := func(t time.Time) bool {
		return (in.Since.IsZero() || !t.Before(in.Since)) && (in.Until.IsZero() || !t.After(in.Until))
	}

	// Operator wallets: administrators and the bootstrap admin handle.
	operators := map[string]bool{}
	var accounts []account.Account
	if e := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"kind": "user"}}, &accounts); e != nil {
		return nil, e
	}
	for _, a := range accounts {
		if a.Role == "admin" || a.Handle == s.K.Env()["admin_handle"] {
			operators[a.ID.String()] = true
		}
	}

	// Income: credit packs sold in the period (test purchases excluded).
	var purchases []models.Record
	if e := s.R.List(ctx, "financial_records", database.Filter{Equal: map[string]any{"kind": "purchase"}}, &purchases); e != nil {
		return nil, e
	}
	var sold, reversed, bought int64
	for _, p := range purchases {
		if sandbox, _ := p.Data["sandbox"].(bool); sandbox || !within(p.CreatedAt) {
			continue
		}
		switch p.Status {
		case "completed":
			sold += p.Amount
			bought++
		case "reversed":
			reversed += p.Amount
		}
	}

	// Spend: what customers were charged for work, by part.
	var settlements []models.Record
	if e := s.R.List(ctx, "financial_records", database.Filter{Equal: map[string]any{"kind": "settlement", "status": "completed"}}, &settlements); e != nil {
		return nil, e
	}
	var charged, compute, tools, llm int64
	for _, r := range settlements {
		if !within(r.CreatedAt) {
			continue
		}
		charged += r.Amount
		compute += amountOf(r.Data["compute_minor"])
		tools += amountOf(r.Data["tool_minor"])
		llm += amountOf(r.Data["llm_minor"])
	}

	// Where spend went, from the ledger.
	var ledger []wallet.LedgerEntry
	if e := s.R.List(ctx, "ledger", database.Filter{}, &ledger); e != nil {
		return nil, e
	}
	var toCreators, opLLM, opNode, opBots int64
	for _, entry := range ledger {
		if !within(entry.CreatedAt) {
			continue
		}
		op := operators[entry.ToID.String()]
		switch entry.Type {
		case wallet.EntryPayLLM:
			if op {
				opLLM += entry.Amount
			} else {
				toCreators += entry.Amount
			}
		case wallet.EntryPayNode:
			if op {
				opNode += entry.Amount
			} else {
				toCreators += entry.Amount
			}
		case wallet.EntryPayBot:
			if op {
				opBots += entry.Amount
			} else {
				toCreators += entry.Amount
			}
		}
	}

	// Credits users still hold (everyone but the operators).
	var wallets []wallet.Wallet
	if e := s.R.List(ctx, "wallets", database.Filter{}, &wallets); e != nil {
		return nil, e
	}
	var held int64
	for _, w := range wallets {
		if !operators[w.OwnerID.String()] {
			held += w.Balance
		}
	}

	return helper.JSON(map[string]any{
		"income":  map[string]any{"credits_sold": sold, "credits_reversed": reversed, "purchases": bought},
		"charged": map[string]any{"total": charged, "compute": compute, "tools": tools, "llm": llm, "agent_time": charged - compute - tools - llm},
		"paid_out": map[string]any{
			"creators": toCreators, "platform_llm": opLLM, "platform_compute": opNode, "platform_bots": opBots,
		},
		"kept":          opLLM + opNode + opBots,
		"held_by_users": held,
		"generated_at":  time.Now().UTC(),
	})
}
