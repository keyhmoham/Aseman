package finance

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/finance/models"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

const (
	grantKind          = "grant"
	grantActive        = "active"
	grantExpired       = "expired"
	grantExpiredPrefix = "credit grant expired"
)

// MintExpiring is Mint for a grant that lapses at expiresAt: whatever part of
// it is still unspent then is taken back by ExpireGrants.
func (s *Service) MintExpiring(ctx context.Context, operator, target identity.ID, amount int64, desc string, expiresAt time.Time) (*wallet.LedgerEntry, error) {
	if !expiresAt.After(time.Now()) {
		return nil, errs.InvalidArgument("expiry must be in the future")
	}
	entry, err := s.Mint(ctx, operator, target, amount, desc)
	if err != nil {
		return nil, err
	}
	id := s.recordID("grant/" + entry.ID.String())
	now := time.Now().UTC()
	err = s.R.DB.Create(ctx, "financial_records", id, &models.Record{
		ID: id, Owner: target.String(), Kind: grantKind, Amount: amount, Status: grantActive,
		Data:      map[string]any{"expires_at": expiresAt.UTC().Format(time.RFC3339), "ledger_seq": entry.Seq},
		CreatedAt: now, UpdatedAt: now,
	})
	if err != nil {
		// The credits are already granted; without the record they simply never expire.
		s.L.Warn("grant expiry record failed", "target", target.String(), "error", err)
	}
	return entry, nil
}

// RunGrantExpiry lapses due grants once a minute (central node only).
func (s *Service) RunGrantExpiry(ctx context.Context) {
	tick := time.NewTicker(time.Minute)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			if !s.isCentral() {
				continue
			}
			if err := s.ExpireGrants(ctx, time.Now()); err != nil {
				s.L.Warn("grant expiry pass failed", "error", err)
			}
		}
	}
}

// ExpireGrants takes back the unspent part of every active grant due by now.
// Spending is assumed to draw on the expiring grant first, so a user's bought
// credits are never touched while the grant still has credits left.
func (s *Service) ExpireGrants(ctx context.Context, now time.Time) error {
	var active []models.Record
	if err := s.R.List(ctx, "financial_records", database.Filter{Equal: map[string]any{"kind": grantKind, "status": grantActive}}, &active); err != nil {
		return err
	}
	for _, g := range active {
		raw, _ := g.Data["expires_at"].(string)
		at, err := time.Parse(time.RFC3339, raw)
		if err != nil || at.After(now) {
			continue
		}
		if err := s.expireGrant(ctx, g); err != nil {
			s.L.Warn("grant expiry failed", "grant", g.ID, "error", err)
		}
	}
	return nil
}

func (s *Service) expireGrant(ctx context.Context, g models.Record) error {
	owner, err := identity.Parse(g.Owner)
	if err != nil {
		return err
	}
	w, err := s.GetWallet(ctx, owner)
	if err != nil {
		return err
	}
	var out []wallet.LedgerEntry
	if err := s.R.List(ctx, "ledger", database.Filter{Equal: map[string]any{"from_id": g.Owner}}, &out); err != nil {
		return err
	}
	var spent int64
	for _, l := range out {
		if l.CreatedAt.Before(g.CreatedAt) || hasPrefix(l.Description, grantExpiredPrefix) {
			continue
		}
		if l.Type == wallet.EntrySpend || l.Type == wallet.EntryTransfer {
			spent += l.Amount
		}
	}
	return s.moneyOperation(ctx, func(ctx context.Context, tx database.Tx, seq int64) error {
		var rec models.Record
		if e := tx.Get(ctx, "financial_records", g.ID, &rec); e != nil {
			return e
		}
		if rec.Status != grantActive {
			return nil
		}
		var bal wallet.Wallet
		if e := tx.Get(ctx, "wallets", w.ID.String(), &bal); e != nil {
			return e
		}
		take := rec.Amount - spent
		if take > bal.Balance {
			take = bal.Balance
		}
		if take < 0 {
			take = 0
		}
		if take > 0 {
			bal.Balance -= take
			bal.UpdatedAt = time.Now().UTC()
			if e := tx.Update(ctx, "wallets", w.ID.String(), &bal); e != nil {
				return e
			}
			if e := s.entry(ctx, tx, seq, wallet.EntrySpend, owner, identity.ID{}, take, grantExpiredPrefix); e != nil {
				return e
			}
		}
		rec.Status = grantExpired
		rec.Data["expired_amount"] = take
		rec.UpdatedAt = time.Now().UTC()
		return tx.Update(ctx, "financial_records", g.ID, &rec)
	})
}

// grantsByEntry is the caller's lapsing grants, by the ledger entry that added them.
func (s *Service) grantsByEntry(ctx context.Context, owner identity.ID) (map[int64]models.Record, error) {
	var records []models.Record
	if err := s.R.List(ctx, "financial_records", database.Filter{Equal: map[string]any{"owner": owner.String(), "kind": grantKind}}, &records); err != nil {
		return nil, err
	}
	out := make(map[int64]models.Record, len(records))
	for _, r := range records {
		out[amountOf(r.Data["ledger_seq"])] = r
	}
	return out, nil
}

// withGrantExpiry adds a lapsing grant's expiry to its line in the person's
// activity. The published apps print `description` as it is, so the text
// carries the expiry to them without a new build; newer clients read the
// fields and show `base_description` beside a badge of their own.
func withGrantExpiry(tx map[string]any, desc string, g models.Record) {
	raw, _ := g.Data["expires_at"].(string)
	at, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return
	}
	base := desc
	if base == "" || base == "mint" {
		base = "Added by Aseman"
	}
	note := "expires " + at.UTC().Format("2 Jan 2006")
	if g.Status == grantExpired {
		note = "expired " + at.UTC().Format("2 Jan 2006")
	}
	tx["grant_status"] = g.Status
	tx["expires_at"] = at.UTC().Format(time.RFC3339)
	tx["base_description"] = base
	tx["description"] = base + " · " + note
}
