package finance

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
)

func TestExpiringGrantTakesBackOnlyUnspentCredits(t *testing.T) {
	s, ctx := financeHarness(t)
	s.K = kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"central": "true"}})
	op := mustID(t, "00000000000000010000000000000003")
	alice := mustID(t, "00000000000000010000000000000001")

	if _, err := s.MintExpiring(ctx, op, alice, 500, "promo", time.Now().Add(-time.Second)); err == nil {
		t.Fatal("past expiry must be rejected")
	}
	if _, err := s.MintExpiring(ctx, op, alice, 500, "promo", time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := s.ExpireGrants(ctx, time.Now()); err != nil {
		t.Fatal(err)
	}
	if w, _ := s.GetWallet(ctx, alice); w.Balance != 1500 {
		t.Fatalf("grant expired early: %d", w.Balance)
	}
	// Alice spends 200 (via a transfer), so only 300 of the grant is left to lapse.
	if _, err := s.Transfer(ctx, alice, mustID(t, "00000000000000010000000000000002"), 200); err != nil {
		t.Fatal(err)
	}
	if err := s.ExpireGrants(ctx, time.Now().Add(2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if w, _ := s.GetWallet(ctx, alice); w.Balance != 1000 {
		t.Fatalf("balance after expiry = %d, want 1000", w.Balance)
	}
	if err := s.ExpireGrants(ctx, time.Now().Add(3*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if w, _ := s.GetWallet(ctx, alice); w.Balance != 1000 {
		t.Fatalf("grant expired twice: %d", w.Balance)
	}
}

// What an admin adds, with or without an expiry, is in the person's own
// activity list (the billing screen's history reads it from there).
func TestGrantsShowInTheAccountsTransactions(t *testing.T) {
	s, ctx := financeHarness(t)
	s.K = kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"central": "true"}})
	op := mustID(t, "00000000000000010000000000000003")
	alice := mustID(t, "00000000000000010000000000000001")
	if _, err := s.Mint(ctx, op, alice, 300, "welcome"); err != nil {
		t.Fatal(err)
	}
	at := time.Now().Add(time.Hour).UTC()
	if _, err := s.MintExpiring(ctx, op, alice, 500, "promo", at); err != nil {
		t.Fatal(err)
	}
	resp, err := s.financialAccount(ctx, &api.ActionRequest{Caller: api.Caller{ID: alice, Kind: "user"}})
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		Transactions []struct {
			Type        string `json:"type"`
			Amount      int64  `json:"amount"`
			Description string `json:"description"`
		} `json:"transactions"`
	}
	if err := json.Unmarshal(resp.Body, &out); err != nil {
		t.Fatal(err)
	}
	seen := map[string]int64{}
	for _, tx := range out.Transactions {
		if tx.Type == "mint" {
			seen[tx.Description] = tx.Amount
		}
	}
	promo := "promo · expires " + at.Format("2 Jan 2006")
	if seen["welcome"] != 300 || seen[promo] != 500 {
		t.Fatalf("grants in the account's activity: %+v (all: %+v)", seen, out.Transactions)
	}
}

// The person sees when a grant lapses in its description (what the published
// apps print), and newer clients get it as fields too.
func TestAccountActivityShowsWhenAGrantLapses(t *testing.T) {
	s, ctx := financeHarness(t)
	s.K = kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"central": "true"}})
	op := mustID(t, "00000000000000010000000000000003")
	alice := mustID(t, "00000000000000010000000000000001")
	if _, err := s.Mint(ctx, op, alice, 30_000, "forever"); err != nil {
		t.Fatal(err)
	}
	at := time.Now().Add(time.Hour).UTC().Truncate(time.Second)
	if _, err := s.MintExpiring(ctx, op, alice, 1_200_000, "", at); err != nil {
		t.Fatal(err)
	}
	read := func() []map[string]any {
		resp, err := s.financialAccount(ctx, &api.ActionRequest{Caller: api.Caller{ID: alice, Kind: "user"}})
		if err != nil {
			t.Fatal(err)
		}
		var out struct {
			Transactions []map[string]any `json:"transactions"`
		}
		if err := json.Unmarshal(resp.Body, &out); err != nil {
			t.Fatal(err)
		}
		mints := []map[string]any{}
		for _, tx := range out.Transactions {
			if tx["type"] == "mint" {
				mints = append(mints, tx)
			}
		}
		return mints
	}
	grant := func(mints []map[string]any) map[string]any {
		for _, m := range mints {
			if m["amount"] == float64(1_200_000) {
				return m
			}
		}
		t.Fatalf("no grant in %+v", mints)
		return nil
	}
	day := at.Format("2 Jan 2006")
	for _, m := range read() {
		if m["description"] == "forever" {
			if _, has := m["expires_at"]; has {
				t.Fatalf("a grant that never lapses shows an expiry: %+v", m)
			}
		}
	}
	g := grant(read())
	if g["description"] != "Added by Aseman · expires "+day || g["base_description"] != "Added by Aseman" || g["grant_status"] != "active" || g["expires_at"] != at.Format(time.RFC3339) {
		t.Fatalf("lapsing grant = %+v", g)
	}
	// 20 credits of the 120 are spent; the other 100 are taken back.
	if _, err := s.Transfer(ctx, alice, mustID(t, "00000000000000010000000000000002"), 200_000); err != nil {
		t.Fatal(err)
	}
	if err := s.ExpireGrants(ctx, at.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	g = grant(read())
	if g["description"] != "Added by Aseman · expired "+day || g["grant_status"] != "expired" {
		t.Fatalf("lapsed grant = %+v", g)
	}
}

// An admin who credits their own account (to try it) is not paying themselves:
// the credits are in their activity as an addition, and a grant to someone else
// is not in the granting admin's own.
func TestAMintIsAnAdditionToWhoReceivesItNotAPaymentByWhoMadeIt(t *testing.T) {
	s, ctx := financeHarness(t)
	s.K = kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"central": "true", "admin_handle": "nodeop"}})
	admin := mustID(t, "00000000000000010000000000000001")
	bob := mustID(t, "00000000000000010000000000000002")
	nodeop := mustID(t, "00000000000000010000000000000003")
	now := time.Now().UTC()
	op := account.Account{Entity: entity.Entity{ID: nodeop, CreatedAt: now, UpdatedAt: now}, Kind: account.KindUser, Handle: "nodeop", Role: "admin", Status: account.StatusActive}
	if err := s.R.CreateID(ctx, "accounts", op.ID, &op); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Mint(ctx, admin, admin, 700, "self test"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Mint(ctx, admin, bob, 400, "for bob"); err != nil {
		t.Fatal(err)
	}
	activity := func(caller identity.ID) map[string]int64 {
		resp, err := s.financialAccount(ctx, &api.ActionRequest{Caller: api.Caller{ID: caller, Kind: "user"}})
		if err != nil {
			t.Fatal(err)
		}
		var out struct {
			Transactions []struct {
				Type        string `json:"type"`
				Amount      int64  `json:"amount"`
				Description string `json:"description"`
			} `json:"transactions"`
		}
		if err := json.Unmarshal(resp.Body, &out); err != nil {
			t.Fatal(err)
		}
		got := map[string]int64{}
		for _, tx := range out.Transactions {
			got[tx.Description] = tx.Amount
		}
		return got
	}
	if got := activity(admin); len(got) != 1 || got["self test"] != 700 {
		t.Fatalf("admin's own activity = %+v, want only +700", got)
	}
	if got := activity(bob); len(got) != 1 || got["for bob"] != 400 {
		t.Fatalf("bob's activity = %+v, want only +400", got)
	}
	// The admin console's view of an account agrees.
	body, _ := json.Marshal(map[string]any{"account": admin.String()})
	resp, err := s.adminAccount(ctx, &api.ActionRequest{Caller: api.Caller{ID: nodeop, Kind: "user"}, Body: body})
	if err != nil {
		t.Fatal(err)
	}
	var seen struct {
		Granted   int64 `json:"granted"`
		Movements []struct {
			Amount int64 `json:"amount"`
		} `json:"movements"`
	}
	if err := json.Unmarshal(resp.Body, &seen); err != nil {
		t.Fatal(err)
	}
	if seen.Granted != 700 || len(seen.Movements) != 1 || seen.Movements[0].Amount != 700 {
		t.Fatalf("admin console view = %+v", seen)
	}
}

// The admin sees when a grant lapses (or that it has) beside the grant.
func TestAdminActivityShowsWhenAGrantLapses(t *testing.T) {
	s, ctx := financeHarness(t)
	s.K = kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"central": "true", "admin_handle": "nodeop"}})
	alice := mustID(t, "00000000000000010000000000000001")
	nodeop := mustID(t, "00000000000000010000000000000003")
	now := time.Now().UTC()
	op := account.Account{Entity: entity.Entity{ID: nodeop, CreatedAt: now, UpdatedAt: now}, Kind: account.KindUser, Handle: "nodeop", Role: "admin", Status: account.StatusActive}
	if err := s.R.CreateID(ctx, "accounts", op.ID, &op); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Mint(ctx, nodeop, alice, 300, "forever"); err != nil {
		t.Fatal(err)
	}
	at := time.Now().Add(time.Hour).UTC().Truncate(time.Second)
	if _, err := s.MintExpiring(ctx, nodeop, alice, 500, "promo", at); err != nil {
		t.Fatal(err)
	}
	read := func() map[string]map[string]any {
		body, _ := json.Marshal(map[string]any{"account": alice.String()})
		resp, err := s.adminAccount(ctx, &api.ActionRequest{Caller: api.Caller{ID: nodeop, Kind: "user"}, Body: body})
		if err != nil {
			t.Fatal(err)
		}
		var out struct {
			Movements []map[string]any `json:"movements"`
		}
		if err := json.Unmarshal(resp.Body, &out); err != nil {
			t.Fatal(err)
		}
		byNote := map[string]map[string]any{}
		for _, m := range out.Movements {
			byNote[m["description"].(string)] = m
		}
		return byNote
	}
	got := read()
	if _, has := got["forever"]["expires_at"]; has {
		t.Fatalf("a grant that never lapses shows an expiry: %+v", got["forever"])
	}
	if got["promo"]["expires_at"] != at.Format(time.RFC3339) || got["promo"]["grant_status"] != "active" {
		t.Fatalf("lapsing grant = %+v", got["promo"])
	}
	if err := s.ExpireGrants(ctx, at.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if got := read(); got["promo"]["grant_status"] != "expired" {
		t.Fatalf("after it lapsed = %+v", got["promo"])
	}
}
