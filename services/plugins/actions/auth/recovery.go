package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"math/big"
	"os"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/crypto"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/mechanisms/mail"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/auth/models/challenge"
	"github.com/aseman/aseman/plugins/actions/auth/models/session"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"golang.org/x/crypto/bcrypt"
)

// ResetPassword preserves the account key. It is called only after a namespace
// has verified a reset challenge or administrator authority.
func (s *Service) ResetPassword(ctx context.Context, id identity.ID, password string) error {
	if len(password) < 8 {
		return errs.InvalidArgument("password must have at least 8 characters")
	}
	var a account.Account
	if e := s.R.Get(ctx, "accounts", id, &a); e != nil {
		return e
	}
	if a.RecoveryKeyEnc == "" || s.K.Env()["node_private_key"] == "" {
		return errs.New(errs.CodeUnavailable, "account identity recovery is not yet initialized; sign in once before resetting")
	}
	priv, e := crypto.DecryptPrivateKey(a.RecoveryKeyEnc, s.K.Env()["node_private_key"])
	if e != nil {
		return errs.New(errs.CodeUnavailable, "account identity recovery failed")
	}
	encrypted, e := crypto.EncryptPrivateKey(priv, password)
	if e != nil {
		return e
	}
	hash, e := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if e != nil {
		return e
	}
	a.PasswordHash = string(hash)
	a.PrivateKeyEnc = encrypted
	a.UpdatedAt = time.Now().UTC()
	if e = s.R.Update(ctx, "accounts", id, &a); e != nil {
		return e
	}
	if link, ok := s.loadOAuthLink(ctx, id); ok && !link.Password {
		link.Password = true
		if e = s.saveOAuthLink(ctx, id, link); e != nil {
			return e
		}
	}
	var rows []session.Session
	if e = s.R.List(ctx, "sessions", database.Filter{Equal: map[string]any{"owner_id": id.String()}}, &rows); e != nil {
		return e
	}
	for _, credential := range rows {
		if e = s.R.Delete(ctx, "sessions", credential.ID); e != nil {
			return e
		}
	}
	return nil
}

// EnvAppleClientIDs lists the accepted Sign in with Apple audiences (the app
// bundle id and/or the web Services ID), comma separated.
const EnvAppleClientIDs = "ASEMAN_APPLE_CLIENT_ID"

const (
	resetCodeTTL      = 15 * time.Minute
	resetResendWindow = time.Minute
)

func recoveryActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "auth", Name: "password_forgot", Summary: "Email a one-time password reset code", Handler: s.passwordForgot},
		helper.Action{Namespace: "auth", Name: "password_reset", Summary: "Reset a password with an emailed one-time code", Handler: s.passwordReset},
		helper.Action{Namespace: "auth", Name: "send_verification", Summary: "Email a one-time email verification code", Handler: s.sendVerification},
		helper.Action{Namespace: "auth", Name: "verify_email", Summary: "Verify email with an emailed one-time code", Handler: s.verifyEmail},
		helper.Action{Namespace: "auth", Name: "resend_verification", Summary: "Resend an email verification code", Handler: s.sendVerification},
		helper.Action{Namespace: "auth", Name: "oauth_apple", Summary: "Sign in / up with a Sign in with Apple identity token", Handler: s.oauthApple},
	}
}

func (s *Service) mailer() mail.Sender {
	if s.Mail == nil {
		s.Mail = mail.FromEnv(s.L)
	}
	return s.Mail
}

func appleClientIDs() []string {
	out := []string{}
	for _, id := range strings.Split(os.Getenv(EnvAppleClientIDs), ",") {
		if id = strings.TrimSpace(id); id != "" {
			out = append(out, id)
		}
	}
	return out
}

func challengeHash(id identity.ID, code string) string {
	h := sha256.Sum256([]byte(id.String() + ":" + code))
	return hex.EncodeToString(h[:])
}

func resetCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

// openChallenges lists an account's redeemable challenges for purpose, newest first.
func (s *Service) openChallenges(ctx context.Context, owner identity.ID, purpose challenge.Purpose) ([]challenge.Challenge, error) {
	var rows []challenge.Challenge
	if err := s.R.List(ctx, "auth_challenges", database.Filter{Equal: map[string]any{"account_id": owner.String(), "purpose": string(purpose)}, OrderBy: "created_at", Asc: false, Limit: 20}, &rows); err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	open := rows[:0]
	for _, row := range rows {
		if row.Open(now) {
			open = append(open, row)
		}
	}
	return open, nil
}

// passwordForgot answers ok for any address so it cannot be used to discover
// which emails have accounts.
func (s *Service) passwordForgot(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Email string `json:"email"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	email := strings.TrimSpace(in.Email)
	if !strings.Contains(email, "@") {
		return nil, errs.InvalidArgument("email is invalid")
	}
	reply := map[string]any{"ok": true, "delivery": s.mailer().Transport()}
	var list []account.Account
	if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"email": email}, Limit: 1}, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 || list[0].Kind != account.KindUser || list[0].Status == account.StatusDisabled {
		return helper.JSON(reply)
	}
	acc := list[0]
	open, err := s.openChallenges(ctx, acc.ID, challenge.PurposePasswordReset)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	if len(open) > 0 && now.Sub(open[0].CreatedAt) < resetResendWindow {
		return helper.JSON(reply)
	}
	// A new code supersedes every earlier one.
	for i := range open {
		open[i].UsedAt, open[i].UpdatedAt = now, now
		_ = s.R.Update(ctx, "auth_challenges", open[i].ID, &open[i])
	}
	code, err := resetCode()
	if err != nil {
		return nil, errs.Wrap(errs.CodeInternal, err, "generate code")
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	c := &challenge.Challenge{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, AccountID: acc.ID, Purpose: challenge.PurposePasswordReset, CodeHash: challengeHash(id, code), ExpiresAt: now.Add(resetCodeTTL)}
	if err = s.R.CreateID(ctx, "auth_challenges", id, c); err != nil {
		return nil, err
	}
	body := fmt.Sprintf("Your password reset code is %s.\n\nIt expires in %d minutes. If you did not ask to reset your password, ignore this email.", code, int(resetCodeTTL/time.Minute))
	if err = s.mailer().Send(ctx, acc.Email, "Your password reset code", body); err != nil {
		s.L.Warn("password reset email failed", "account", acc.ID.String(), "error", err)
		return nil, errs.Wrap(errs.CodeUnavailable, err, "could not send the reset email")
	}
	return helper.JSON(reply)
}

func (s *Service) passwordReset(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Email    string `json:"email"`
		Code     string `json:"code"`
		Password string `json:"password"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	invalid := errs.InvalidArgument("invalid or expired code")
	if len(in.Password) < 8 {
		return nil, errs.InvalidArgument("password must be at least 8 characters")
	}
	code := strings.TrimSpace(in.Code)
	var list []account.Account
	if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"email": strings.TrimSpace(in.Email)}, Limit: 1}, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 || code == "" {
		return nil, invalid
	}
	acc := list[0]
	open, err := s.openChallenges(ctx, acc.ID, challenge.PurposePasswordReset)
	if err != nil {
		return nil, err
	}
	if len(open) == 0 {
		return nil, invalid
	}
	c := open[0]
	now := time.Now().UTC()
	if subtle.ConstantTimeCompare([]byte(c.CodeHash), []byte(challengeHash(c.ID, code))) != 1 {
		c.Attempts++
		c.UpdatedAt = now
		_ = s.R.Update(ctx, "auth_challenges", c.ID, &c)
		return nil, invalid
	}
	// Burn the code before changing anything so it can only be redeemed once.
	c.UsedAt, c.UpdatedAt = now, now
	changed, err := s.R.CompareAndSwap(ctx, "auth_challenges", c.ID.String(), map[string]any{"code_hash": c.CodeHash, "attempts": c.Attempts}, &c)
	if err != nil {
		return nil, err
	}
	if !changed {
		return nil, invalid
	}
	if err = s.ResetPassword(ctx, acc.ID, in.Password); err != nil {
		return nil, err
	}
	if !acc.EmailVerified || acc.Status == account.StatusPending {
		if fresh, e := s.Account(ctx, acc.Handle); e == nil {
			fresh.EmailVerified = true
			if fresh.Status == account.StatusPending {
				fresh.Status = account.StatusActive
			}
			fresh.UpdatedAt = now
			_ = s.R.Update(ctx, "accounts", fresh.ID, fresh)
		}
	}
	return helper.JSON(map[string]any{"ok": true})
}

// sendVerificationCode generates, stores, and sends an email verification code.
func (s *Service) sendVerificationCode(ctx context.Context, acc *account.Account) (string, error) {
	open, err := s.openChallenges(ctx, acc.ID, challenge.PurposeEmailVerification)
	if err != nil {
		return "", err
	}
	now := time.Now().UTC()
	for i := range open {
		open[i].UsedAt, open[i].UpdatedAt = now, now
		_ = s.R.Update(ctx, "auth_challenges", open[i].ID, &open[i])
	}
	code, err := resetCode()
	if err != nil {
		return "", errs.Wrap(errs.CodeInternal, err, "generate code")
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return "", err
	}
	c := &challenge.Challenge{
		Entity:    entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		AccountID: acc.ID,
		Purpose:   challenge.PurposeEmailVerification,
		CodeHash:  challengeHash(id, code),
		ExpiresAt: now.Add(resetCodeTTL),
	}
	if err = s.R.CreateID(ctx, "auth_challenges", id, c); err != nil {
		return "", err
	}
	body := fmt.Sprintf("Your Aseman verification code is %s.\n\nIt expires in %d minutes. Enter it to verify your email and activate your account.", code, int(resetCodeTTL/time.Minute))
	if err = s.mailer().Send(ctx, acc.Email, "Your verification code", body); err != nil {
		s.L.Warn("verification email failed", "account", acc.ID.String(), "error", err)
		return "", errs.Wrap(errs.CodeUnavailable, err, "could not send the verification email")
	}
	return code, nil
}

// sendVerification handles auth.send_verification and auth.resend_verification.
func (s *Service) sendVerification(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Email string `json:"email"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	email := strings.TrimSpace(in.Email)
	reply := map[string]any{"ok": true, "delivery": s.mailer().Transport()}
	if email == "" || !strings.Contains(email, "@") {
		return helper.JSON(reply)
	}
	var list []account.Account
	if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"email": email}, Limit: 1}, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return helper.JSON(reply)
	}
	acc := list[0]
	if acc.EmailVerified && acc.Status == account.StatusActive {
		return helper.JSON(reply)
	}
	open, err := s.openChallenges(ctx, acc.ID, challenge.PurposeEmailVerification)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	if len(open) > 0 && now.Sub(open[0].CreatedAt) < resetResendWindow {
		return helper.JSON(reply)
	}
	if _, err := s.sendVerificationCode(ctx, &acc); err != nil {
		return nil, err
	}
	return helper.JSON(reply)
}

// verifyEmail handles auth.verify_email.
func (s *Service) verifyEmail(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Email    string `json:"email"`
		Code     string `json:"code"`
		Password string `json:"password"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	invalid := errs.InvalidArgument("invalid or expired verification code")
	code := strings.TrimSpace(in.Code)
	email := strings.TrimSpace(in.Email)
	if email == "" || code == "" {
		return nil, invalid
	}
	var list []account.Account
	if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"email": email}, Limit: 1}, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, invalid
	}
	acc := list[0]
	open, err := s.openChallenges(ctx, acc.ID, challenge.PurposeEmailVerification)
	if err != nil {
		return nil, err
	}
	if len(open) == 0 {
		return nil, invalid
	}
	c := open[0]
	now := time.Now().UTC()
	if subtle.ConstantTimeCompare([]byte(c.CodeHash), []byte(challengeHash(c.ID, code))) != 1 {
		c.Attempts++
		c.UpdatedAt = now
		_ = s.R.Update(ctx, "auth_challenges", c.ID, &c)
		return nil, invalid
	}
	c.UsedAt, c.UpdatedAt = now, now
	changed, err := s.R.CompareAndSwap(ctx, "auth_challenges", c.ID.String(), map[string]any{"code_hash": c.CodeHash, "attempts": c.Attempts}, &c)
	if err != nil {
		return nil, err
	}
	if !changed {
		return nil, invalid
	}

	// Update account status to active and email_verified to true.
	acc.EmailVerified = true
	acc.Status = account.StatusActive
	acc.UpdatedAt = now
	if err := s.R.Update(ctx, "accounts", acc.ID, &acc); err != nil {
		return nil, err
	}

	// If password provided, sign them in directly and return full SignIn payload.
	if in.Password != "" {
		if err := bcrypt.CompareHashAndPassword([]byte(acc.PasswordHash), []byte(in.Password)); err == nil {
			priv, err := s.PrivateKey(ctx, &acc, in.Password)
			if err == nil {
				token, err := s.IssueToken(ctx, acc.ID, session.KindSession)
				if err == nil {
					return helper.JSON(map[string]any{
						"ok":            true,
						"account_id":    acc.ID.String(),
						"handle":        acc.Handle,
						"token":         token,
						"private_key":   priv,
						"public_key":    acc.PublicKey,
						"home_space_id": s.HomeSpaceID(ctx, acc.ID),
					})
				}
			}
		}
	}

	return helper.JSON(map[string]any{"ok": true})
}

func (s *Service) oauthApple(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		IdentityToken string `json:"identity_token"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	audiences := appleClientIDs()
	if len(audiences) == 0 {
		return nil, errs.New(errs.CodeUnavailable, "apple sign-in is not configured")
	}
	claims, err := crypto.VerifyAppleIdentityToken(ctx, in.IdentityToken, audiences)
	if err != nil {
		return nil, errs.Wrap(errs.CodeInvalidArgument, err, "invalid apple token")
	}
	acc, token, priv, isNew, err := s.OAuthSignIn(ctx, "apple", claims)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{
		"account_id": acc.ID.String(), "handle": acc.Handle,
		"token": token, "private_key": priv, "public_key": acc.PublicKey, "new": isNew,
		"home_space_id": s.HomeSpaceID(ctx, acc.ID),
	})
}
