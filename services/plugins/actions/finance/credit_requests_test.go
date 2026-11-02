package finance

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
)

type captureMail struct{ to, subject, body string }

func (m *captureMail) Send(_ context.Context, to, subject, body string) error {
	m.to, m.subject, m.body = to, subject, body
	return nil
}
func (m *captureMail) Transport() string { return "test" }

func creditReq(caller api.Caller, body any) *api.ActionRequest {
	b, _ := json.Marshal(body)
	return &api.ActionRequest{Caller: caller, Body: b}
}

func TestCreditRequestIsGrantedOnceAndTheyAreEmailed(t *testing.T) {
	s, ctx := financeHarness(t)
	s.K = kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"central": "true", "admin_handle": "nodeop"}})
	mailbox := &captureMail{}
	s.Mail = mailbox
	alice := mustID(t, "00000000000000010000000000000001")
	op := mustID(t, "00000000000000010000000000000003")
	now := time.Now().UTC()
	for _, a := range []*account.Account{
		{Entity: entity.Entity{ID: alice, CreatedAt: now, UpdatedAt: now}, Kind: account.KindUser, Handle: "alice", Email: "alice@example.com", Status: account.StatusActive},
		{Entity: entity.Entity{ID: op, CreatedAt: now, UpdatedAt: now}, Kind: account.KindUser, Handle: "nodeop", Status: account.StatusActive},
	} {
		if err := s.R.CreateID(ctx, "accounts", a.ID, a); err != nil {
			t.Fatal(err)
		}
	}
	user := api.Caller{ID: alice, Kind: "user"}
	admin := api.Caller{ID: op, Kind: "user"}

	if _, err := s.creditRequest(ctx, creditReq(user, map[string]any{"reason": "too short"})); err == nil {
		t.Fatal("a short reason must be rejected")
	}
	res, err := s.creditRequest(ctx, creditReq(user, map[string]any{"reason": "I am building a research crew for my bakery and need to try it."}))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.creditRequest(ctx, creditReq(user, map[string]any{"reason": "I am building a research crew for my bakery and need to try it."})); err == nil {
		t.Fatal("a second pending request must be rejected")
	}
	var made struct {
		Request struct{ ID string }
	}
	_ = json.Unmarshal(res.Body, &made)

	if _, err := s.creditRequestsList(ctx, creditReq(user, nil)); err == nil {
		t.Fatal("the queue is for the admin")
	}
	if _, err := s.creditRequestResolve(ctx, creditReq(admin, map[string]any{"id": made.Request.ID, "status": "approved"})); err == nil {
		t.Fatal("approving needs an amount")
	}
	if _, err := s.creditRequestResolve(ctx, creditReq(admin, map[string]any{"id": made.Request.ID, "status": "approved", "amount": 500, "note": "Welcome!"})); err != nil {
		t.Fatal(err)
	}
	if w, _ := s.GetWallet(ctx, alice); w.Balance != 1500 {
		t.Fatalf("balance = %d, want 1500", w.Balance)
	}
	if mailbox.to != "alice@example.com" || !strings.Contains(mailbox.body, "Welcome!") {
		t.Fatalf("email = %+v", mailbox)
	}
	if _, err := s.creditRequestResolve(ctx, creditReq(admin, map[string]any{"id": made.Request.ID, "status": "approved", "amount": 500})); err == nil {
		t.Fatal("a request is granted once")
	}
	if w, _ := s.GetWallet(ctx, alice); w.Balance != 1500 {
		t.Fatalf("granted twice: %d", w.Balance)
	}
}
