package finance

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

func clientActions(s *Service) []api.Action {
	var actions []api.Action
	add := func(name, summary string, fn func(context.Context, *api.ActionRequest) (*api.ActionResponse, error)) {
		actions = append(actions, helper.Action{Namespace: "finance", Name: name, Summary: summary, Handler: fn})
	}
	add("budget_set", "Set an authoritative project spend cap", s.budgetSet)
	add("account", "Financial account and actual ledger activity", s.financialAccount)
	add("payout_request", "Reserve creator earnings for payout", s.payoutRequest)
	add("payouts_list", "Admin payout queue", s.payoutsList)
	add("payout_resolve", "Resolve a reserved payout", s.payoutResolve)
	add("purchase_confirm", "Verify and credit a store transaction", s.purchaseConfirm)
	add("purchases_mine", "Own purchase history", func(c context.Context, r *api.ActionRequest) (*api.ActionResponse, error) {
		return s.purchasesList(c, r, true)
	})
	add("purchases_list", "Admin purchases", func(c context.Context, r *api.ActionRequest) (*api.ActionResponse, error) {
		return s.purchasesList(c, r, false)
	})
	add("purchases_label", "Label purchase test transactions", s.purchaseLabel)
	add("admin_account", "Admin: one account's purchases, grants and spend", s.adminAccount)
	add("credit_request", "Ask for complimentary credits", s.creditRequest)
	add("credit_requests_mine", "Own complimentary credit requests", s.creditRequestsMine)
	add("credit_requests_list", "Admin: complimentary credit requests", s.creditRequestsList)
	add("credit_request_resolve", "Admin: grant or decline a credit request, and email the person", s.creditRequestResolve)
	add("provider_costs", "Admin: what the machine provider billed for project computers", s.providerCosts)
	add("overview", "Admin: income, spend by part, payouts and net for a period", s.overview)
	add("reconcile", "Inspect financial reconciliation issues", s.reconcileAction)
	add("costs", "Actual provider and compute ledger payouts", func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
		if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
			return nil, e
		}
		var rows []wallet.LedgerEntry
		if e := s.R.List(ctx, "ledger", database.Filter{}, &rows); e != nil {
			return nil, e
		}
		var llm, compute int64
		for _, r := range rows {
			if r.Type == wallet.EntryPayLLM {
				llm += r.Amount
			}
			if r.Type == wallet.EntryPayNode {
				compute += r.Amount
			}
		}
		return helper.JSON(map[string]any{"llm": llm, "compute": compute, "total": llm + compute})
	})
	return actions
}
