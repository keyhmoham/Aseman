package auth

import (
	"context"
	"encoding/json"
	"regexp"
	"testing"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	devmodels "github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

type capturedMail struct{ to, body string }

type captureSender struct{ sent []capturedMail }

func (c *captureSender) Transport() string { return "test" }
func (c *captureSender) Send(_ context.Context, to, _ string, body string) error {
	c.sent = append(c.sent, capturedMail{to: to, body: body})
	return nil
}

func recoveryHarness(t *testing.T) (*Service, *captureSender, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"node_private_key": "test-node-recovery-secret"}})
	mail := &captureSender{}
	s := &Service{K: k, R: &repo.Repo{DB: db}, L: logger.Global(), Mail: mail}
	return s, mail, ctx
}

func call(t *testing.T, ctx context.Context, h func(context.Context, *api.ActionRequest) (*api.ActionResponse, error), body map[string]any) error {
	t.Helper()
	raw, _ := json.Marshal(body)
	_, err := h(ctx, &api.ActionRequest{Body: raw})
	return err
}

func TestPasswordResetWithEmailedCode(t *testing.T) {
	s, mail, ctx := recoveryHarness(t)
	if _, _, _, err := s.Register(ctx, "alice", "alice@example.com", "first-password"); err != nil {
		t.Fatal(err)
	}

	// Unknown addresses answer ok and send nothing.
	if err := call(t, ctx, s.passwordForgot, map[string]any{"email": "nobody@example.com"}); err != nil {
		t.Fatal(err)
	}
	if len(mail.sent) != 0 {
		t.Fatal("no mail may be sent for an unknown address")
	}

	if err := call(t, ctx, s.passwordForgot, map[string]any{"email": "alice@example.com"}); err != nil {
		t.Fatal(err)
	}
	if len(mail.sent) != 1 || mail.sent[0].to != "alice@example.com" {
		t.Fatalf("expected one reset mail, got %+v", mail.sent)
	}
	code := regexp.MustCompile(`\b\d{6}\b`).FindString(mail.sent[0].body)
	if code == "" {
		t.Fatal("mail must carry a 6 digit code")
	}

	wrong := "000000"
	if wrong == code {
		wrong = "111111"
	}
	if err := call(t, ctx, s.passwordReset, map[string]any{"email": "alice@example.com", "code": wrong, "password": "second-password"}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("wrong code must be rejected, got %v", err)
	}
	if err := call(t, ctx, s.passwordReset, map[string]any{"email": "alice@example.com", "code": code, "password": "second-password"}); err != nil {
		t.Fatalf("reset with the mailed code: %v", err)
	}
	if _, _, _, err := s.Login(ctx, "alice", "first-password"); err == nil {
		t.Fatal("old password must stop working")
	}
	acc, _, priv, err := s.Login(ctx, "alice", "second-password")
	if err != nil || priv == "" {
		t.Fatalf("new password must unlock the same identity key: %v", err)
	}
	if !acc.EmailVerified {
		t.Fatal("redeeming an emailed code proves the address")
	}
	if err := call(t, ctx, s.passwordReset, map[string]any{"email": "alice@example.com", "code": code, "password": "third-password"}); err == nil {
		t.Fatal("a code can only be redeemed once")
	}
}

func TestPasswordResetCodeBurnsAfterMaxAttempts(t *testing.T) {
	s, mail, ctx := recoveryHarness(t)
	if _, _, _, err := s.Register(ctx, "bob", "bob@example.com", "first-password"); err != nil {
		t.Fatal(err)
	}
	if err := call(t, ctx, s.passwordForgot, map[string]any{"email": "bob@example.com"}); err != nil {
		t.Fatal(err)
	}
	code := regexp.MustCompile(`\b\d{6}\b`).FindString(mail.sent[0].body)
	wrong := "000000"
	if wrong == code {
		wrong = "111111"
	}
	for i := 0; i < 5; i++ {
		_ = call(t, ctx, s.passwordReset, map[string]any{"email": "bob@example.com", "code": wrong, "password": "second-password"})
	}
	if err := call(t, ctx, s.passwordReset, map[string]any{"email": "bob@example.com", "code": code, "password": "second-password"}); err == nil {
		t.Fatal("the right code must not work after too many wrong guesses")
	}
}

func TestEmailVerificationWithCode(t *testing.T) {
	s, mail, ctx := recoveryHarness(t)
	acc, _, _, err := s.Register(ctx, "carol", "carol@example.com", "first-password")
	if err != nil {
		t.Fatal(err)
	}
	if acc.EmailVerified {
		t.Fatal("new registered account should not be email verified initially")
	}
	if acc.Status != "pending" {
		t.Fatalf("new registered account status should be pending, got %s", acc.Status)
	}

	// Login before verification must fail
	if _, _, _, err := s.Login(ctx, "carol", "first-password"); err == nil {
		t.Fatal("login before email verification must be rejected")
	}

	// Send verification code
	if err := call(t, ctx, s.sendVerification, map[string]any{"email": "carol@example.com"}); err != nil {
		t.Fatal(err)
	}
	if len(mail.sent) != 1 || mail.sent[0].to != "carol@example.com" {
		t.Fatalf("expected one verification mail, got %+v", mail.sent)
	}
	code := regexp.MustCompile(`\b\d{6}\b`).FindString(mail.sent[0].body)
	if code == "" {
		t.Fatal("mail must carry a 6-digit verification code")
	}

	// Wrong code should fail
	wrong := "000000"
	if wrong == code {
		wrong = "111111"
	}
	if err := call(t, ctx, s.verifyEmail, map[string]any{"email": "carol@example.com", "code": wrong}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("wrong code must be rejected, got %v", err)
	}

	// Correct code should verify email
	if err := call(t, ctx, s.verifyEmail, map[string]any{"email": "carol@example.com", "code": code, "password": "first-password"}); err != nil {
		t.Fatalf("verify with the mailed code: %v", err)
	}

	// Verify account state
	fresh, err := s.Account(ctx, "carol")
	if err != nil {
		t.Fatal(err)
	}
	if !fresh.EmailVerified {
		t.Fatal("account must be marked email_verified after successful verification")
	}
	if fresh.Status != "active" {
		t.Fatalf("account status must be active after verification, got %s", fresh.Status)
	}

	// Login after verification must succeed
	if _, _, _, err := s.Login(ctx, "carol", "first-password"); err != nil {
		t.Fatalf("login after email verification must succeed, got %v", err)
	}

	// Admin account (or admin_handle) does not require email verification to login
	if _, _, _, err := s.Register(ctx, "admin-test", "admin-test@localhost", "admin-secret-pass"); err != nil {
		t.Fatal(err)
	}
	adm, err := s.Account(ctx, "admin-test")
	if err != nil {
		t.Fatal(err)
	}
	adm.Role = "admin"
	adm.EmailVerified = false
	adm.Status = account.StatusPending
	if err := s.R.Update(ctx, "accounts", adm.ID, adm); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := s.Login(ctx, "admin-test", "admin-secret-pass"); err != nil {
		t.Fatalf("admin account must be able to log in without email verification: %v", err)
	}
}

func TestBootstrapAdminDoesNotRecreateIfAdminExists(t *testing.T) {
	ctx := context.Background()
	k := kernel.New(kernel.Options{
		NodeID: 1,
		Logger: logger.Global(),
		Env: map[string]string{
			"admin_handle":   "node-master",
			"admin_password": "masterpassword",
		},
	})
	db := memory.New(logger.Global())
	for _, m := range dbmodel.Models() {
		_ = db.RegisterModel(ctx, m)
	}
	r := &repo.Repo{DB: db}
	s := &Service{K: k, R: r, L: logger.Global()}

	// First bootstrap: creates node-master
	if err := s.Bootstrap(ctx); err != nil {
		t.Fatalf("first bootstrap failed: %v", err)
	}
	acc, err := s.Account(ctx, "node-master")
	if err != nil {
		t.Fatalf("expected node-master account to exist: %v", err)
	}
	if acc.Role != "admin" {
		t.Fatalf("expected role admin, got %s", acc.Role)
	}

	// Now rename / change username of admin to "superadmin"
	acc.Handle = "superadmin"
	if err := s.R.Update(ctx, "accounts", acc.ID, acc); err != nil {
		t.Fatalf("failed to update handle: %v", err)
	}

	// Verify "node-master" no longer exists
	if _, err := s.Account(ctx, "node-master"); err == nil {
		t.Fatal("expected node-master to not exist after rename")
	}

	// Run Bootstrap again. Because an admin account ("superadmin") exists, it should NOT recreate "node-master".
	if err := s.Bootstrap(ctx); err != nil {
		t.Fatalf("second bootstrap failed: %v", err)
	}

	if _, err := s.Account(ctx, "node-master"); err == nil {
		t.Fatal("expected node-master to NOT be recreated because an admin account already exists")
	}
}

// An email is unique per environment: resetting on a platform touches that
// platform's account, never main Aseman's with the same address.
func TestPasswordResetStaysOnItsPlatform(t *testing.T) {
	s, mail, ctx := recoveryHarness(t)
	id, _ := identity.New(1)
	pid := id.String()
	if err := s.R.CreateID(ctx, "dev_platforms", id, &devmodels.Platform{Entity: entity.Entity{ID: id}, Slug: "acme", Name: "Acme"}); err != nil {
		t.Fatal(err)
	}
	mainAcc, _, _, err := s.RegisterOn(ctx, "sam", "sam@example.com", "main-password", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := s.RegisterOn(ctx, "sam", "sam@example.com", "acme-password", pid); err != nil {
		t.Fatal(err)
	}
	if err := call(t, ctx, s.passwordForgot, map[string]any{"email": "sam@example.com", "platform": "acme"}); err != nil {
		t.Fatal(err)
	}
	code := regexp.MustCompile(`\b\d{6}\b`).FindString(mail.sent[len(mail.sent)-1].body)
	// The code is the platform account's: main Aseman's account cannot use it.
	if err := call(t, ctx, s.passwordReset, map[string]any{"email": "sam@example.com", "code": code, "password": "stolen-password"}); err == nil {
		t.Fatal("a platform's code reset main Aseman's account")
	}
	if err := call(t, ctx, s.passwordReset, map[string]any{"email": "sam@example.com", "code": code, "password": "new-acme-password", "platform": "acme"}); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := s.LoginOn(ctx, "sam", "new-acme-password", pid); err != nil {
		t.Fatalf("the platform account: %v", err)
	}
	var after account.Account
	if err := s.R.Get(ctx, "accounts", mainAcc.ID, &after); err != nil || after.PasswordHash != mainAcc.PasswordHash || after.EmailVerified {
		t.Fatalf("main Aseman's account must be untouched: %v", err)
	}
	if err := call(t, ctx, s.passwordForgot, map[string]any{"email": "sam@example.com", "platform": "nope"}); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("unknown platform: %v", err)
	}
}
