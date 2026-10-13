package finance

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/finance/models"
	"github.com/tradera/tradera/plugins/actions/finance/models/wallet"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
)

// Verification contacts the configured purchase authority. Client price/credit
// assertions are never used to mint funds.
func (s *Service) verifyPurchase(ctx context.Context, owner, product, transaction string) (int64, map[string]any, error) {
	key := os.Getenv("TRADERA_REVENUECAT_SECRET")
	if key == "" {
		return 0, nil, errs.New(errs.CodeUnavailable, "purchase verification is not configured")
	}
	packs := map[string]int64{"tradera_topup_20": 20000000, "tradera_topup_50": 50000000, "tradera_topup_100": 100000000}
	if raw := os.Getenv("TRADERA_REVENUECAT_PRODUCTS"); raw != "" {
		if e := json.Unmarshal([]byte(raw), &packs); e != nil {
			return 0, nil, errs.New(errs.CodeUnavailable, "invalid purchase product configuration")
		}
	}
	amount, ok := packs[product]
	if !ok || amount <= 0 {
		return 0, nil, errs.InvalidArgument("unknown credit product")
	}
	if transaction == "" {
		return 0, nil, errs.InvalidArgument("store transaction id required")
	}
	purchases, e := s.subscriberPurchases(ctx, owner)
	if e != nil {
		return 0, nil, e
	}
	for _, row := range purchases[product] {
		if row["id"] == transaction || row["store_transaction_id"] == transaction {
			if row["refund_date"] != nil || row["refunded_at"] != nil {
				return 0, nil, errs.Permission("purchase has been refunded")
			}
			return amount, row, nil
		}
	}
	return 0, nil, errs.Permission("transaction is not verified for this account")
}

// subscriberPurchases reads the account's one-time purchases from the purchase
// authority, by product.
func (s *Service) subscriberPurchases(ctx context.Context, owner string) (map[string][]map[string]any, error) {
	base := os.Getenv("TRADERA_REVENUECAT_URL")
	if base == "" {
		base = "https://api.revenuecat.com/v1"
	}
	req, e := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(base, "/")+"/subscribers/"+url.PathEscape(owner), nil)
	if e != nil {
		return nil, e
	}
	req.Header.Set("Authorization", "Bearer "+os.Getenv("TRADERA_REVENUECAT_SECRET"))
	req.Header.Set("Accept", "application/json")
	resp, e := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if e != nil {
		return nil, errs.New(errs.CodeUnavailable, "purchase provider could not be reached")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, errs.New(errs.CodeUnavailable, "purchase provider refused verification")
	}
	var body struct {
		Subscriber struct {
			Purchases map[string][]map[string]any `json:"non_subscriptions"`
		} `json:"subscriber"`
	}
	b, e := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if e != nil {
		return nil, e
	}
	if e = json.Unmarshal(b, &body); e != nil {
		return nil, e
	}
	return body.Subscriber.Purchases, nil
}

// storeCharge is what the purchase authority's purchases API holds for one
// purchase: its ids and the revenue it brought in, which is the amount after
// any discount.
type storeCharge struct {
	ID       string
	StoreID  string
	Gross    float64
	Currency string
}

// revenueConfigured reports whether the node can ask for what purchases
// actually cost (TRADERA_REVENUECAT_PROJECT is set).
func revenueConfigured() bool { return os.Getenv("TRADERA_REVENUECAT_PROJECT") != "" }

// storeCharges lists what the account's purchases actually cost.
func (s *Service) storeCharges(ctx context.Context, owner string) ([]storeCharge, error) {
	project := os.Getenv("TRADERA_REVENUECAT_PROJECT")
	key := os.Getenv("TRADERA_REVENUECAT_V2_SECRET")
	if key == "" {
		key = os.Getenv("TRADERA_REVENUECAT_SECRET")
	}
	if project == "" || key == "" {
		return nil, errs.New(errs.CodeUnavailable, "purchase revenue lookup is not configured")
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	base := os.Getenv("TRADERA_REVENUECAT_V2_URL")
	if base == "" {
		base = "https://api.revenuecat.com/v2"
	}
	req, e := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(base, "/")+"/projects/"+url.PathEscape(project)+"/customers/"+url.PathEscape(owner)+"/purchases?limit=100", nil)
	if e != nil {
		return nil, e
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Accept", "application/json")
	resp, e := (&http.Client{}).Do(req)
	if e != nil {
		return nil, e
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode != 200 {
		// The provider's own words say what to fix (a v1 key, a wrong project id).
		return nil, errs.New(errs.CodeUnavailable, "purchase revenue lookup answered "+resp.Status+": "+strings.TrimSpace(string(raw[:min(len(raw), 300)])))
	}
	var body struct {
		Items []struct {
			ID      string `json:"id"`
			StoreID string `json:"store_purchase_identifier"`
			Revenue *struct {
				Currency string  `json:"currency"`
				Gross    float64 `json:"gross"`
			} `json:"revenue_in_usd"`
		} `json:"items"`
	}
	if e := json.Unmarshal(raw, &body); e != nil {
		return nil, e
	}
	out := make([]storeCharge, 0, len(body.Items))
	for _, it := range body.Items {
		if it.Revenue == nil {
			continue
		}
		currency := strings.ToUpper(it.Revenue.Currency)
		if currency == "" {
			currency = "USD"
		}
		out = append(out, storeCharge{ID: it.ID, StoreID: it.StoreID, Gross: it.Revenue.Gross, Currency: currency})
	}
	return out, nil
}

// chargeFor finds a purchase among the store's charges by any of its ids.
func chargeFor(charges []storeCharge, ids ...string) (storeCharge, bool) {
	want := map[string]bool{}
	for _, id := range ids {
		if id != "" {
			want[id] = true
		}
	}
	for _, c := range charges {
		if want[c.ID] || want[c.StoreID] {
			return c, true
		}
	}
	return storeCharge{}, false
}

// paidFromStore reads what the store charged for a verified purchase, when the
// purchase authority reports it: the price on its own record of the
// transaction, else the revenue its purchases API holds for it.
func (s *Service) paidFromStore(ctx context.Context, owner, transaction string, verified map[string]any) (float64, string, bool) {
	if price, _ := verified["price"].(map[string]any); price != nil {
		amount, _ := price["amount"].(float64)
		currency, _ := price["currency"].(string)
		if amount > 0 && currency != "" {
			return amount, strings.ToUpper(currency), true
		}
	}
	if !revenueConfigured() {
		return 0, "", false
	}
	charges, e := s.storeCharges(ctx, owner)
	if e != nil {
		if s.L != nil {
			s.L.Warn("purchase revenue lookup failed", "account", owner, "error", e)
		}
		return 0, "", false
	}
	id, _ := verified["id"].(string)
	storeID, _ := verified["store_transaction_id"].(string)
	// Zero is a real answer: a pack bought with a full discount.
	if c, ok := chargeFor(charges, transaction, id, storeID); ok {
		return c.Gross, c.Currency, true
	}
	return 0, "", false
}

// learnCharges fills in what earlier purchases actually cost: records made
// before the node kept it, or that know only a list price. One account at a
// time, asked at most once every few minutes, and never in the way of the
// list it is called from.
func (s *Service) learnCharges(ctx context.Context, owner string, rows []models.Record) {
	if !revenueConfigured() {
		return
	}
	var missing []int
	for i := range rows {
		if rows[i].Owner == owner && rows[i].Data["paid_source"] != "store" {
			missing = append(missing, i)
		}
	}
	if len(missing) == 0 {
		return
	}
	s.chargesMu.Lock()
	if s.chargesAsked == nil {
		s.chargesAsked = map[string]time.Time{}
	}
	if time.Since(s.chargesAsked[owner]) < 5*time.Minute {
		s.chargesMu.Unlock()
		return
	}
	s.chargesAsked[owner] = time.Now()
	s.chargesMu.Unlock()

	charges, e := s.storeCharges(ctx, owner)
	if e != nil {
		if s.L != nil {
			s.L.Warn("purchase revenue lookup failed", "account", owner, "error", e)
		}
		return
	}
	// A record names its transaction by one id; the store's charge may be
	// filed under the other. The subscriber record pairs them.
	pairs := map[string]string{}
	if purchases, e := s.subscriberPurchases(ctx, owner); e == nil {
		for _, list := range purchases {
			for _, row := range list {
				id, _ := row["id"].(string)
				storeID, _ := row["store_transaction_id"].(string)
				if id != "" && storeID != "" {
					pairs[id], pairs[storeID] = storeID, id
				}
			}
		}
	}
	for _, i := range missing {
		tx, _ := rows[i].Data["transaction_id"].(string)
		if tx == "" {
			tx, _ = rows[i].Data["transactionId"].(string)
		}
		c, ok := chargeFor(charges, tx, pairs[tx])
		if !ok {
			continue
		}
		var r models.Record
		if e := s.R.GetString(ctx, "financial_records", rows[i].ID, &r); e != nil {
			continue
		}
		if r.Data == nil {
			r.Data = map[string]any{}
		}
		r.Data["paid_amount"], r.Data["paid_currency"], r.Data["paid_source"] = c.Gross, c.Currency, "store"
		r.UpdatedAt = time.Now().UTC()
		if e := s.R.UpdateString(ctx, "financial_records", r.ID, &r); e == nil {
			rows[i] = r
		}
	}
}

// paidDetails is what a purchase record keeps about the money that changed
// hands. "store" is the charge the purchase authority reports; "listed" is the
// price the buyer's own store showed for the pack, which a discount may have
// lowered. Neither is ever used to decide how many credits are granted.
func (s *Service) paidDetails(ctx context.Context, owner, transaction string, verified map[string]any, listed float64, listedCurrency string) map[string]any {
	if amount, currency, ok := s.paidFromStore(ctx, owner, transaction, verified); ok {
		return map[string]any{"paid_amount": amount, "paid_currency": currency, "paid_source": "store"}
	}
	listedCurrency = strings.ToUpper(strings.TrimSpace(listedCurrency))
	if listed > 0 && listed < 1e7 && len(listedCurrency) == 3 {
		return map[string]any{"paid_amount": listed, "paid_currency": listedCurrency, "paid_source": "listed"}
	}
	return nil
}

func purchaseView(r models.Record) map[string]any {
	out := map[string]any{"id": r.ID, "account_id": r.Owner, "amount": r.Amount, "status": map[string]string{"completed": "credited", "pending": "pending", "failed": "failed", "reversed": "reversed"}[r.Status], "created_at": r.CreatedAt, "updated_at": r.UpdatedAt}
	for k, v := range r.Data {
		switch k { // records written before the keys were normalized
		case "productId":
			k = "product_id"
		case "transactionId":
			k = "transaction_id"
		}
		out[k] = v
	}
	return out
}
func (s *Service) purchaseConfirm(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		Product     string `json:"product_id"`
		Transaction string `json:"transaction_id"`
		// The pack's price on the store it was bought from, for the receipt only.
		Listed         float64 `json:"listed_amount,omitempty"`
		ListedCurrency string  `json:"listed_currency,omitempty"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	amount, verified, e := s.verifyPurchase(ctx, req.Caller.ID.String(), in.Product, in.Transaction)
	if e != nil {
		return nil, e
	}
	paid := s.paidDetails(ctx, req.Caller.ID.String(), in.Transaction, verified, in.Listed, in.ListedCurrency)
	id := s.recordID("purchase/" + in.Transaction)
	w, e := s.GetWallet(ctx, req.Caller.ID)
	if e != nil {
		return nil, e
	}
	now := time.Now().UTC()
	record := models.Record{ID: id, Owner: req.Caller.ID.String(), Kind: "purchase", Amount: amount, Status: "completed", Data: map[string]any{"product_id": in.Product, "transaction_id": in.Transaction, "sandbox": verified["is_sandbox"] == true, "store": verified["store"]}, CreatedAt: now, UpdatedAt: now}
	for k, v := range paid {
		record.Data[k] = v
	}
	e = s.moneyOperation(ctx, func(ctx context.Context, tx database.Tx, seq int64) error {
		var old models.Record
		if e := tx.Get(ctx, "financial_records", id, &old); e == nil {
			if old.Owner != record.Owner || (old.Data["product_id"] != in.Product && old.Data["productId"] != in.Product) {
				return errs.Permission("transaction was credited to a different account")
			}
			record = old
			// A purchase credited before its charge was known (or known only
			// as a list price) learns it now; nothing else about it changes.
			if paid != nil && (old.Data["paid_source"] == nil || (old.Data["paid_source"] == "listed" && paid["paid_source"] == "store")) {
				if record.Data == nil {
					record.Data = map[string]any{}
				}
				for k, v := range paid {
					record.Data[k] = v
				}
				record.UpdatedAt = now
				return tx.Update(ctx, "financial_records", id, &record)
			}
			return nil
		} else if errs.CodeOf(e) != errs.CodeNotFound {
			return e
		}
		var balance wallet.Wallet
		if e := tx.Get(ctx, "wallets", w.ID.String(), &balance); e != nil {
			return e
		}
		balance.Balance += amount
		balance.UpdatedAt = now
		if e := tx.Update(ctx, "wallets", w.ID.String(), &balance); e != nil {
			return e
		}
		if e := tx.Create(ctx, "financial_records", id, &record); e != nil {
			return e
		}
		return s.entry(ctx, tx, seq, wallet.EntryMint, identity.ID{}, req.Caller.ID, amount, "verified purchase "+in.Transaction)
	})
	if e != nil {
		return nil, e
	}
	return helper.JSON(map[string]any{"ok": true, "purchase": purchaseView(record), "credited": true})
}
func (s *Service) purchasesList(ctx context.Context, req *api.ActionRequest, mine bool) (*api.ActionResponse, error) {
	if mine {
		if e := helper.RequireUser(req); e != nil {
			return nil, e
		}
	} else {
		if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
			return nil, e
		}
	}
	eq := map[string]any{"kind": "purchase"}
	if mine {
		eq["owner"] = req.Caller.ID.String()
	}
	var rows []models.Record
	if e := s.R.List(ctx, "financial_records", database.Filter{Equal: eq, OrderBy: "created_at", Asc: false}, &rows); e != nil {
		return nil, e
	}
	// Purchases that do not know what was actually paid yet learn it here: the
	// buyer's own list at once, an admin's list a few accounts per reading.
	owners, seen := []string{}, map[string]bool{}
	for _, r := range rows {
		if !seen[r.Owner] && r.Data["paid_source"] != "store" {
			seen[r.Owner] = true
			owners = append(owners, r.Owner)
		}
	}
	for _, owner := range owners[:min(len(owners), 8)] {
		s.learnCharges(ctx, owner, rows)
	}
	out := []map[string]any{}
	for _, r := range rows {
		out = append(out, purchaseView(r))
	}
	return helper.JSON(map[string]any{"purchases": out})
}
func (s *Service) purchaseLabel(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var in struct {
		IDs     []string `json:"transaction_ids"`
		Sandbox bool     `json:"sandbox"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	var updated int
	for _, tid := range in.IDs {
		key := s.recordID("purchase/" + tid)
		var r models.Record
		if e := s.R.GetString(ctx, "financial_records", key, &r); e != nil {
			return nil, e
		}
		r.Data["sandbox"] = in.Sandbox
		r.UpdatedAt = time.Now().UTC()
		if e := s.R.UpdateString(ctx, "financial_records", key, &r); e != nil {
			return nil, e
		}
		updated++
	}
	return helper.JSON(map[string]any{"updated": updated})
}
