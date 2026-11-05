package finance

import (
	"context"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/finance/models"
	"github.com/aseman/aseman/plugins/actions/support/emailtpl"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/mail"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Complimentary credit requests: a person asks for free credits and says why;
// the admin grants (with an amount they choose) or declines. Requests are
// financial records of kind "credit_request"; Amount is what was asked for in
// ledger units, and the granted amount is in Data["granted"].
const (
	creditRequestKind = "credit_request"
	creditPending     = "pending"
	creditApproved    = "approved"
	creditDeclined    = "declined"

	minCreditReason = 20
	maxCreditReason = 1000
	maxCreditNote   = 500
	// maxCreditAskUSD bounds what a person can ask for.
	maxCreditAskUSD = 1000
	// unitsPerUSD is the ledger scale (see unitsOf).
	unitsPerUSD = 1_000_000
)

func (s *Service) mailer() mail.Sender {
	if s.Mail == nil {
		s.Mail = mail.FromEnv(s.L)
	}
	return s.Mail
}

func creditView(r models.Record) map[string]any {
	out := map[string]any{
		"id": r.ID, "owner": r.Owner, "requested": r.Amount, "status": r.Status,
		"created_at": r.CreatedAt, "updated_at": r.UpdatedAt,
	}
	for _, k := range []string{"reason", "granted", "note", "resolved_at", "expires_at", "emailed", "developer_api"} {
		if v, ok := r.Data[k]; ok {
			out[k] = v
		}
	}
	return out
}

// creditRequest files a request. One pending request per person at a time.
func (s *Service) creditRequest(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		Reason string `json:"reason"`
		// AmountUSD is optional: what they would like, in dollars.
		AmountUSD float64 `json:"amount_usd"`
		RequestID string  `json:"request_id"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	reason := strings.TrimSpace(strings.ReplaceAll(in.Reason, "\r\n", "\n"))
	if n := utf8.RuneCountInString(reason); n < minCreditReason || n > maxCreditReason {
		return nil, errs.InvalidArgument(fmt.Sprintf("Tell us what you want the credits for, in %d to %d characters.", minCreditReason, maxCreditReason))
	}
	if math.IsNaN(in.AmountUSD) || math.IsInf(in.AmountUSD, 0) || in.AmountUSD < 0 || in.AmountUSD > maxCreditAskUSD {
		return nil, errs.InvalidArgument(fmt.Sprintf("The amount must be between $0 and $%d.", maxCreditAskUSD))
	}
	var mine []models.Record
	if e := s.R.List(ctx, "financial_records", database.Filter{Equal: map[string]any{"owner": req.Caller.ID.String(), "kind": creditRequestKind, "status": creditPending}}, &mine); e != nil {
		return nil, e
	}
	if len(mine) > 0 {
		return nil, errs.Conflict("You already have a request waiting. We’ll email you when it has been reviewed.")
	}
	now := time.Now().UTC()
	id := s.recordID("credit_request/" + req.Caller.ID.String() + "/" + now.Format(time.RFC3339Nano))
	if in.RequestID != "" {
		id = s.recordID("credit_request/" + req.Caller.ID.String() + "/" + in.RequestID)
	}
	rec := models.Record{
		ID: id, Owner: req.Caller.ID.String(), Kind: creditRequestKind, Status: creditPending,
		Amount:    int64(math.Round(in.AmountUSD * unitsPerUSD)),
		Data:      map[string]any{"reason": reason},
		CreatedAt: now, UpdatedAt: now,
	}
	if e := s.R.DB.Create(ctx, "financial_records", id, &rec); e != nil {
		if errs.CodeOf(e) != errs.CodeAlreadyExists {
			return nil, e
		}
		if e = s.R.GetString(ctx, "financial_records", id, &rec); e != nil {
			return nil, e
		}
	}
	return helper.JSON(map[string]any{"ok": true, "request": creditView(rec)})
}

func (s *Service) creditRequestsMine(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var rows []models.Record
	if e := s.R.List(ctx, "financial_records", database.Filter{Equal: map[string]any{"owner": req.Caller.ID.String(), "kind": creditRequestKind}, OrderBy: "created_at", Asc: false}, &rows); e != nil {
		return nil, e
	}
	out := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		out = append(out, creditView(r))
	}
	return helper.JSON(map[string]any{"requests": out})
}

// creditRequestsList is the admin's queue: every request with who asked.
func (s *Service) creditRequestsList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var rows []models.Record
	if e := s.R.List(ctx, "financial_records", database.Filter{Equal: map[string]any{"kind": creditRequestKind}}, &rows); e != nil {
		return nil, e
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].CreatedAt.After(rows[j].CreatedAt) })
	out := make([]map[string]any, 0, len(rows))
	people := map[string]*account.Account{}
	for _, r := range rows {
		v := creditView(r)
		p, ok := people[r.Owner]
		if !ok {
			var a account.Account
			if id, e := identity.Parse(r.Owner); e == nil && s.R.Get(ctx, "accounts", id, &a) == nil {
				p = &a
			}
			people[r.Owner] = p
		}
		if p != nil {
			v["handle"], v["email"], v["email_verified"] = p.Handle, p.Email, p.EmailVerified
		}
		if id, e := identity.Parse(r.Owner); e == nil {
			if w, e := s.GetWallet(ctx, id); e == nil {
				v["balance"] = w.Balance
			}
		}
		out = append(out, v)
	}
	return helper.JSON(map[string]any{"requests": out})
}

// creditRequestResolve grants or declines a pending request, then emails the person.
func (s *Service) creditRequestResolve(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var in struct {
		ID     string `json:"id"`
		Status string `json:"status"`
		// Amount is what to grant, in ledger units (approve only).
		Amount int64 `json:"amount"`
		// ExpiresAt (RFC 3339) makes the grant lapse; empty means it never does.
		ExpiresAt string `json:"expires_at"`
		Note      string `json:"note"`
		// DeveloperAPI says whether the credits can also be used on the Developer
		// API (and sent to others); defaults to true.
		DeveloperAPI *bool `json:"developer_api"`
		// Notify emails the person; defaults to true.
		Notify *bool `json:"notify"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	if in.Status != creditApproved && in.Status != creditDeclined {
		return nil, errs.InvalidArgument("status must be approved or declined")
	}
	note := strings.TrimSpace(in.Note)
	if utf8.RuneCountInString(note) > maxCreditNote {
		return nil, errs.InvalidArgument(fmt.Sprintf("The note must be at most %d characters.", maxCreditNote))
	}
	var expires time.Time
	if in.Status == creditApproved {
		if in.Amount <= 0 {
			return nil, errs.InvalidArgument("amount must be positive")
		}
		if in.ExpiresAt != "" {
			at, err := time.Parse(time.RFC3339, in.ExpiresAt)
			if err != nil {
				return nil, errs.InvalidArgument("expires_at must be an RFC 3339 time")
			}
			expires = at
		}
	}
	var rec models.Record
	if e := s.R.GetString(ctx, "financial_records", in.ID, &rec); e != nil {
		return nil, e
	}
	if rec.Kind != creditRequestKind {
		return nil, errs.NotFound("credit request")
	}
	owner, e := identity.Parse(rec.Owner)
	if e != nil {
		return nil, e
	}
	// Claim the request first so two admins can't both grant it; give it back if the grant fails.
	claimed := rec
	claimed.Status = in.Status
	claimed.UpdatedAt = time.Now().UTC()
	claimed.Data = map[string]any{}
	for k, v := range rec.Data {
		claimed.Data[k] = v
	}
	claimed.Data["resolved_at"] = claimed.UpdatedAt.Format(time.RFC3339)
	if note != "" {
		claimed.Data["note"] = note
	}
	swapped, e := s.R.CompareAndSwap(ctx, "financial_records", rec.ID, map[string]any{"status": creditPending}, &claimed)
	if e != nil {
		return nil, e
	}
	if !swapped {
		return nil, errs.Conflict("This request has already been reviewed.")
	}
	if in.Status == creditApproved {
		desc := "Complimentary credits"
		limited := in.DeveloperAPI != nil && !*in.DeveloperAPI
		if _, err := s.MintGrant(ctx, req.Caller.ID, owner, in.Amount, desc, expires, limited); err != nil {
			_, _ = s.R.CompareAndSwap(context.WithoutCancel(ctx), "financial_records", rec.ID, map[string]any{"status": in.Status}, &rec)
			return nil, err
		}
		if !expires.IsZero() {
			claimed.Data["expires_at"] = expires.UTC().Format(time.RFC3339)
		}
		claimed.Data["developer_api"] = !limited
		claimed.Data["granted"] = in.Amount
	}
	if in.Notify == nil || *in.Notify {
		claimed.Data["emailed"] = s.emailCreditDecision(ctx, owner, in.Status, in.Amount, expires, note)
	}
	if e := s.R.UpdateString(ctx, "financial_records", claimed.ID, &claimed); e != nil {
		s.L.Warn("credit request update failed", "request", claimed.ID, "error", e)
	}
	return helper.JSON(map[string]any{"ok": true, "request": creditView(claimed)})
}

// emailCreditDecision tells the person the outcome; it reports whether it was sent.
// A mail problem never undoes the decision.
func (s *Service) emailCreditDecision(ctx context.Context, owner identity.ID, status string, amount int64, expires time.Time, note string) bool {
	var a account.Account
	if err := s.R.Get(ctx, "accounts", owner, &a); err != nil || a.Email == "" {
		return false
	}
	name := a.Handle
	if name == "" {
		name = "there"
	}
	vars := map[string]string{"name": name}
	if note != "" {
		vars["note_line"] = "A note from the team:\n" + note
	}
	key := "credit_declined"
	if status == creditApproved {
		key = "credit_granted"
		vars["credits"] = creditsLabel(amount)
		if !expires.IsZero() {
			vars["expiry_line"] = fmt.Sprintf("These credits expire on %s. Any part you haven’t used by then is taken back.", expires.UTC().Format("2 Jan 2006"))
		}
	}
	if err := emailtpl.Send(ctx, s.K, s.mailer(), a.Email, key, vars); err != nil {
		s.L.Warn("credit application email failed", "to", owner.String(), "error", err)
		return false
	}
	return true
}

// creditsLabel prints ledger units as credits (100 per USD, 1,000,000 units per USD).
func creditsLabel(units int64) string {
	c := float64(units) / (unitsPerUSD / 100)
	if c == math.Trunc(c) {
		return fmt.Sprintf("%d credits", int64(c))
	}
	return fmt.Sprintf("%.2f credits", c)
}
