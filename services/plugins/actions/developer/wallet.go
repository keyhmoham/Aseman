package developer

import (
	"context"
	"sort"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/finance/models/wallet"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// WalletEntryView is one movement of an organization's balance; a charge is negative.
type WalletEntryView struct {
	ID          string `json:"id"`
	At          string `json:"at"`
	Description string `json:"description"`
	Amount      int64  `json:"amount"`
}

// WalletView is an organization's balance and what moved it lately.
type WalletView struct {
	Balance int64             `json:"balance"`
	Entries []WalletEntryView `json:"entries"`
}

// Wallet reads an organization's balance and its recent movements: funds added
// and what the API charged.
func (s *Service) Wallet(ctx context.Context, sc Scope) (*WalletView, error) {
	w, err := s.Fin.GetWallet(ctx, sc.Org)
	if err != nil {
		return nil, err
	}
	view := &WalletView{Balance: w.Available(), Entries: []WalletEntryView{}}
	var in, out []wallet.LedgerEntry
	if err := s.R.List(ctx, "ledger", database.Filter{Equal: map[string]any{"to_id": sc.Org.String(), "type": string(wallet.EntryTransfer)}, OrderBy: "seq", Limit: 100}, &in); err != nil {
		return nil, err
	}
	if err := s.R.List(ctx, "ledger", database.Filter{Equal: map[string]any{"from_id": sc.Org.String(), "type": string(wallet.EntrySpend)}, OrderBy: "seq", Limit: 100}, &out); err != nil {
		return nil, err
	}
	for _, e := range in {
		view.Entries = append(view.Entries, WalletEntryView{ID: e.ID.String(), At: stamp(e.CreatedAt), Description: "Funds added", Amount: e.Amount})
	}
	for _, e := range out {
		view.Entries = append(view.Entries, WalletEntryView{ID: e.ID.String(), At: stamp(e.CreatedAt), Description: e.Description, Amount: -e.Amount})
	}
	sortEntries(view.Entries)
	if len(view.Entries) > 100 {
		view.Entries = view.Entries[:100]
	}
	return view, nil
}

func sortEntries(list []WalletEntryView) {
	sort.SliceStable(list, func(i, j int) bool { return list[i].At > list[j].At })
}

// Fund moves money from the caller's own balance to the organization's.
func (s *Service) Fund(ctx context.Context, caller identity.ID, sc Scope, amount int64) (*WalletView, error) {
	if sc.Personal {
		return nil, errs.InvalidArgument("Your personal organization uses your own balance: add funds in Billing.")
	}
	if err := sc.Require("billing"); err != nil {
		return nil, err
	}
	if amount < 10_000 {
		return nil, errs.InvalidArgument("Add at least $0.01.")
	}
	if amount > 100_000_000_000 {
		return nil, errs.InvalidArgument("That is more than can be added at once.")
	}
	if _, err := s.Fin.Transfer(ctx, caller, sc.Org, amount); err != nil {
		if errs.CodeOf(err) == errs.CodeFinance {
			return nil, errs.New(errs.CodeFinance, "Your own balance is too low for that. Add funds to it in the app's Billing first.")
		}
		return nil, err
	}
	return s.Wallet(ctx, sc)
}

// SettingsView are an organization's own limits.
type SettingsView struct {
	AccountMonthlyCap int64 `json:"accountMonthlyCap"`
	LowBalanceAlert   int64 `json:"lowBalanceAlert"`
	SpentMonth        int64 `json:"spentMonth"`
}

// Settings reads an organization's limits.
func (s *Service) Settings(ctx context.Context, sc Scope) (*SettingsView, error) {
	st, err := s.settings(ctx, sc.Org)
	if err != nil {
		return nil, err
	}
	spent := st.MonthSpent
	if st.MonthKey != monthKey(s.now()) {
		spent = 0
	}
	return &SettingsView{AccountMonthlyCap: st.MonthlyCap, LowBalanceAlert: st.LowBalance, SpentMonth: spent}, nil
}

// SaveSettings changes an organization's limits.
func (s *Service) SaveSettings(ctx context.Context, sc Scope, in SettingsView) (*SettingsView, error) {
	if err := sc.Require("settings"); err != nil {
		return nil, err
	}
	if in.AccountMonthlyCap < 0 || in.LowBalanceAlert < 0 {
		return nil, errs.InvalidArgument("Limits cannot be negative.")
	}
	st, err := s.settings(ctx, sc.Org)
	if err != nil {
		return nil, err
	}
	st.MonthlyCap, st.LowBalance, st.UpdatedAt = in.AccountMonthlyCap, in.LowBalanceAlert, s.now()
	if err := s.R.DB.Update(ctx, "dev_settings", sc.Org.String(), st); err != nil {
		return nil, err
	}
	return s.Settings(ctx, sc)
}
