package finance

import (
	"context"
	"encoding/json"
	"math"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/finance/models"
	"github.com/tradera/tradera/plugins/actions/finance/models/wallet"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
)

func (s *Service) recordID(key string) string {
	return s.K.NodeID().String() + repo.ExecutionKey(key)[16:]
}

// MoneyOperation serializes ledger mutation across nodes using the repository's
// durable lease; no provider-specific SQL or process-local wallet locks.
func (s *Service) moneyOperation(ctx context.Context, fn func(context.Context, database.Tx, int64) error) error {
	var lease *repo.ExecutionLease
	var e error
	for i := 0; i < 20; i++ {
		lease, e = repo.ClaimExecution(ctx, s.R, s.K.NodeID(), "financial-ledger/"+s.K.NodeID().String(), time.Minute)
		if e == nil {
			break
		}
		if errs.CodeOf(e) != errs.CodeConflict {
			return e
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(25 * time.Millisecond):
		}
	}
	if e != nil {
		return e
	}
	defer lease.Release(context.WithoutCancel(ctx), s.R)
	seq, e := s.MaxSeq(ctx)
	if e != nil {
		return e
	}
	return s.R.DB.Transaction(ctx, func(ctx context.Context, tx database.Tx) error { return fn(ctx, tx, seq+1) })
}
func (s *Service) entry(ctx context.Context, tx database.Tx, seq int64, typ wallet.EntryType, from, to identity.ID, amount int64, description string) error {
	id, e := identity.New(s.K.NodeID())
	if e != nil {
		return e
	}
	return tx.Create(ctx, "ledger", id.String(), &wallet.LedgerEntry{ID: id, Seq: seq, NodeID: s.K.NodeID(), Type: typ, FromID: from, ToID: to, Amount: amount, Description: description, CreatedAt: time.Now().UTC()})
}
func (s *Service) ReserveEscrow(ctx context.Context, owner identity.ID, reference string, amount int64) error {
	if amount <= 0 {
		return errs.InvalidArgument("positive amount required")
	}
	w, e := s.GetWallet(ctx, owner)
	if e != nil {
		return e
	}
	key := s.recordID("escrow/" + reference)
	return s.moneyOperation(ctx, func(ctx context.Context, tx database.Tx, seq int64) error {
		var old models.Record
		if e := tx.Get(ctx, "financial_records", key, &old); e == nil {
			if old.Owner != owner.String() || old.Amount != amount {
				return errs.Conflict("reservation reference reused")
			}
			return nil
		} else if errs.CodeOf(e) != errs.CodeNotFound {
			return e
		}
		var balance wallet.Wallet
		if e := tx.Get(ctx, "wallets", w.ID.String(), &balance); e != nil {
			return e
		}
		if balance.Balance < amount {
			return errs.New(errs.CodeFinance, "insufficient available balance")
		}
		balance.Balance -= amount
		balance.Locked += amount
		balance.UpdatedAt = time.Now().UTC()
		if e := tx.Update(ctx, "wallets", w.ID.String(), &balance); e != nil {
			return e
		}
		now := time.Now().UTC()
		if e := tx.Create(ctx, "financial_records", key, &models.Record{ID: key, Owner: owner.String(), Kind: "escrow", Amount: amount, Status: "held", Data: map[string]any{"reference": reference}, CreatedAt: now, UpdatedAt: now}); e != nil {
			return e
		}
		return s.entry(ctx, tx, seq, wallet.EntryPoolLock, owner, identity.ID{}, amount, "escrow "+reference)
	})
}
func (s *Service) ResolveEscrow(ctx context.Context, owner, recipient identity.ID, reference string, accept bool) error {
	w, e := s.GetWallet(ctx, owner)
	if e != nil {
		return e
	}
	var payee *wallet.Wallet
	if accept {
		payee, e = s.GetWallet(ctx, recipient)
		if e != nil {
			return e
		}
	}
	key := s.recordID("escrow/" + reference)
	return s.moneyOperation(ctx, func(ctx context.Context, tx database.Tx, seq int64) error {
		var record models.Record
		if e := tx.Get(ctx, "financial_records", key, &record); e != nil {
			return e
		}
		if record.Owner != owner.String() {
			return errs.Permission("reservation owner mismatch")
		}
		status := "released"
		if accept {
			status = "settled"
		}
		if record.Status == status {
			return nil
		}
		if record.Status != "held" {
			return errs.Conflict("reservation already resolved")
		}
		var balance wallet.Wallet
		if e := tx.Get(ctx, "wallets", w.ID.String(), &balance); e != nil {
			return e
		}
		if balance.Locked < record.Amount {
			return errs.Conflict("reserved funds are missing")
		}
		balance.Locked -= record.Amount
		if !accept {
			balance.Balance += record.Amount
		}
		balance.UpdatedAt = time.Now().UTC()
		if e := tx.Update(ctx, "wallets", w.ID.String(), &balance); e != nil {
			return e
		}
		if accept {
			var received wallet.Wallet
			if e := tx.Get(ctx, "wallets", payee.ID.String(), &received); e != nil {
				return e
			}
			received.Balance += record.Amount
			received.UpdatedAt = time.Now().UTC()
			if e := tx.Update(ctx, "wallets", payee.ID.String(), &received); e != nil {
				return e
			}
		}
		record.Status = status
		record.UpdatedAt = time.Now().UTC()
		if e := tx.Update(ctx, "financial_records", key, &record); e != nil {
			return e
		}
		typ := wallet.EntryPoolFree
		if accept {
			typ = wallet.EntryPayBot
		}
		return s.entry(ctx, tx, seq, typ, owner, recipient, record.Amount, "escrow "+reference)
	})
}
func (s *Service) financialAccount(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	w, e := s.GetWallet(ctx, req.Caller.ID)
	if e != nil {
		return nil, e
	}
	var entries []wallet.LedgerEntry
	if e = s.R.List(ctx, "ledger", database.Filter{OrderBy: "created_at", Asc: false}, &entries); e != nil {
		return nil, e
	}
	transactions := []map[string]any{}
	var earned, spent, deposits, receivedTransfers, sentTransfers int64
	for _, l := range entries {
		if l.FromID != req.Caller.ID && l.ToID != req.Caller.ID {
			continue
		}
		change := l.Amount
		if l.FromID == req.Caller.ID {
			change = -l.Amount
			if l.Type != wallet.EntryPoolLock && l.Type != wallet.EntryPoolFree {
				spent += l.Amount
			}
		}
		if l.ToID == req.Caller.ID && (l.Type == wallet.EntryPayBot || l.Type == wallet.EntryPayNode || l.Type == wallet.EntryPayLLM) {
			earned += l.Amount
		}
		if l.Type == wallet.EntryMint && l.ToID == req.Caller.ID {
			deposits += l.Amount
		}
		if l.Type == wallet.EntryTransfer {
			if l.ToID == req.Caller.ID {
				receivedTransfers += l.Amount
			}
			if l.FromID == req.Caller.ID {
				sentTransfers += l.Amount
			}
		}
		transactions = append(transactions, map[string]any{"id": l.ID.String(), "type": l.Type, "amount": change, "from_id": l.FromID.String(), "to_id": l.ToID.String(), "description": l.Description, "created_at": l.CreatedAt})
	}
	var records []models.Record
	if e = s.R.List(ctx, "financial_records", database.Filter{Equal: map[string]any{"owner": req.Caller.ID.String(), "kind": "payout"}}, &records); e != nil {
		return nil, e
	}
	payouts := []map[string]any{}
	var held, paid int64
	for _, p := range records {
		payouts = append(payouts, payoutView(p))
		if p.Status == "pending" {
			held += p.Amount
		}
		if p.Status == "paid" {
			paid += p.Amount
		}
	}
	// Distribution entries are not second debits. Derive net spent from the
	// actual wallet and funding journals, including still-reserved funds.
	spent = max(deposits+receivedTransfers+earned-sentTransfers-paid-w.Balance-w.Locked, 0)
	withdrawable := int64(math.Min(float64(w.Balance), float64(max(earned-spent-sentTransfers-paid-held, 0))))
	return helper.JSON(map[string]any{"balance": w.Balance, "locked": w.Locked, "withdrawable": withdrawable, "payout_held": held, "earned": earned, "spent": spent, "transactions": transactions, "payouts": payouts})
}
func payoutView(p models.Record) map[string]any {
	out := map[string]any{"id": p.ID, "account_id": p.Owner, "amount": p.Amount, "status": p.Status, "created_at": p.CreatedAt, "updated_at": p.UpdatedAt}
	for k, v := range p.Data {
		out[k] = v
	}
	return out
}
func (s *Service) payoutRequest(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		Amount      int64           `json:"amount"`
		RequestID   string          `json:"request_id"`
		Method      string          `json:"method"`
		Destination json.RawMessage `json:"destination"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	if in.Amount <= 0 || in.RequestID == "" {
		return nil, errs.InvalidArgument("positive amount and request_id required")
	}
	accountResp, e := s.financialAccount(ctx, req)
	if e != nil {
		return nil, e
	}
	var account struct {
		Withdrawable int64 `json:"withdrawable"`
	}
	_ = json.Unmarshal(accountResp.Body, &account)
	if account.Withdrawable < in.Amount {
		return nil, errs.New(errs.CodeFinance, "insufficient withdrawable earnings")
	}
	id := s.recordID("payout/" + req.Caller.ID.String() + "/" + in.RequestID)
	if e = s.ReserveEscrow(ctx, req.Caller.ID, "payout/"+id, in.Amount); e != nil {
		return nil, e
	}
	now := time.Now().UTC()
	record := models.Record{ID: id, Owner: req.Caller.ID.String(), Kind: "payout", Amount: in.Amount, Status: "pending", Data: map[string]any{"method": in.Method, "destination": in.Destination, "reference": "payout/" + id}, CreatedAt: now, UpdatedAt: now}
	if e = s.R.EnsureCreated(ctx, "financial_records", identity.MustParse(id), &record); e != nil {
		return nil, e
	}
	return helper.JSON(map[string]any{"ok": true, "payout": payoutView(record)})
}
func (s *Service) payoutsList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var rows []models.Record
	if e := s.R.List(ctx, "financial_records", database.Filter{Equal: map[string]any{"kind": "payout"}, OrderBy: "created_at", Asc: false}, &rows); e != nil {
		return nil, e
	}
	out := []map[string]any{}
	for _, r := range rows {
		out = append(out, payoutView(r))
	}
	return helper.JSON(map[string]any{"payouts": out})
}
func (s *Service) payoutResolve(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var in struct {
		ID                string `json:"payout_id"`
		Resolution        string `json:"resolution_id"`
		Status            string `json:"status"`
		ProviderReference string `json:"provider_reference"`
		Reason            string `json:"reason"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	if in.Status != "paid" && in.Status != "rejected" {
		return nil, errs.InvalidArgument("status must be paid or rejected")
	}
	if in.Resolution == "" {
		return nil, errs.InvalidArgument("resolution_id required")
	}
	var p models.Record
	if e := s.R.GetString(ctx, "financial_records", in.ID, &p); e != nil {
		return nil, e
	}
	if p.Kind != "payout" {
		return nil, errs.InvalidArgument("not a payout")
	}
	if p.Status == in.Status {
		return helper.JSON(map[string]any{"ok": true, "payout": payoutView(p)})
	}
	if p.Status != "pending" {
		return nil, errs.Conflict("payout already resolved")
	}
	owner, e := identity.Parse(p.Owner)
	if e != nil {
		return nil, e
	}
	w, e := s.GetWallet(ctx, owner)
	if e != nil {
		return nil, e
	}
	key := s.recordID("escrow/payout/" + p.ID)
	e = s.moneyOperation(ctx, func(ctx context.Context, tx database.Tx, seq int64) error {
		var current models.Record
		if e := tx.Get(ctx, "financial_records", p.ID, &current); e != nil {
			return e
		}
		if current.Status != "pending" {
			return errs.Conflict("payout already resolved")
		}
		var hold models.Record
		if e := tx.Get(ctx, "financial_records", key, &hold); e != nil {
			return e
		}
		if hold.Status != "held" {
			return errs.Conflict("payout reservation already resolved")
		}
		var balance wallet.Wallet
		if e := tx.Get(ctx, "wallets", w.ID.String(), &balance); e != nil {
			return e
		}
		if balance.Locked < p.Amount {
			return errs.Conflict("payout reserved balance mismatch")
		}
		balance.Locked -= p.Amount
		if in.Status == "rejected" {
			balance.Balance += p.Amount
		}
		balance.UpdatedAt = time.Now().UTC()
		if e := tx.Update(ctx, "wallets", w.ID.String(), &balance); e != nil {
			return e
		}
		current.Status = in.Status
		current.Data["provider_reference"] = in.ProviderReference
		current.Data["reason"] = in.Reason
		current.Data["resolution_id"] = in.Resolution
		current.UpdatedAt = time.Now().UTC()
		if e := tx.Update(ctx, "financial_records", p.ID, &current); e != nil {
			return e
		}
		hold.Status = in.Status
		hold.UpdatedAt = current.UpdatedAt
		if e := tx.Update(ctx, "financial_records", key, &hold); e != nil {
			return e
		}
		typ := wallet.EntryType("payout")
		if in.Status == "rejected" {
			typ = wallet.EntryPoolFree
		}
		return s.entry(ctx, tx, seq, typ, owner, identity.ID{}, p.Amount, "payout "+p.ID)
	})
	if e != nil {
		return nil, e
	}
	return helper.JSON(map[string]any{"ok": true})
}
