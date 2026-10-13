package finance

import (
	"testing"
	"time"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/pkg/logger"
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
