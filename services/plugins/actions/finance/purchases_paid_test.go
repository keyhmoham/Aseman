package finance

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPaidDetailsPreferTheStoresChargeOverTheListPrice(t *testing.T) {
	s := &Service{}
	ctx := context.Background()
	// The store's own record of the transaction carries the price.
	got := s.paidDetails(ctx, "acc", "tx1", map[string]any{"price": map[string]any{"amount": 11.49, "currency": "gbp"}}, 22.99, "GBP")
	if got["paid_amount"] != 11.49 || got["paid_currency"] != "GBP" || got["paid_source"] != "store" {
		t.Fatalf("store price not used: %v", got)
	}
	// Nothing from the store: the list price is kept, marked as such.
	got = s.paidDetails(ctx, "acc", "tx1", map[string]any{}, 22.99, "gbp")
	if got["paid_amount"] != 22.99 || got["paid_currency"] != "GBP" || got["paid_source"] != "listed" {
		t.Fatalf("list price not kept: %v", got)
	}
	if got := s.paidDetails(ctx, "acc", "tx1", map[string]any{}, 0, ""); got != nil {
		t.Fatalf("nothing known must stay unknown: %v", got)
	}
}

func TestPaidDetailsReadTheDiscountedChargeFromThePurchasesAPI(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/projects/proj1/customers/acc/purchases" || r.Header.Get("Authorization") != "Bearer sk" {
			http.Error(w, "no", http.StatusForbidden)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"items": []map[string]any{
			{"id": "other", "store_purchase_identifier": "zzz", "revenue_in_usd": map[string]any{"currency": "USD", "gross": 50}},
			{"id": "p1", "store_purchase_identifier": "store-tx", "revenue_in_usd": map[string]any{"currency": "USD", "gross": 10}},
		}})
	}))
	defer srv.Close()
	t.Setenv("TRADERA_REVENUECAT_PROJECT", "proj1")
	t.Setenv("TRADERA_REVENUECAT_SECRET", "sk")
	t.Setenv("TRADERA_REVENUECAT_V2_URL", srv.URL)
	s := &Service{}
	got := s.paidDetails(context.Background(), "acc", "rc-id", map[string]any{"id": "rc-id", "store_transaction_id": "store-tx"}, 20, "USD")
	if got["paid_amount"] != 10.0 || got["paid_currency"] != "USD" || got["paid_source"] != "store" {
		t.Fatalf("discounted charge not used: %v", got)
	}
}
