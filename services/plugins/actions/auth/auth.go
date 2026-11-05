// Package auth implements the auth namespace: register, login, logout,
// sessions and OAuth (Google) sign in.
package auth

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/crypto"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/idutil"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/support/mail"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/auth/models/session"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/models/metadata"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"

	"golang.org/x/crypto/bcrypt"
)

// Service holds auth dependencies.
type Service struct {
	K      api.Kernel
	R      *repo.Repo
	Spaces SpacesPort
	L      *logger.Logger
	// Mail delivers one-time codes; nil resolves from the environment.
	Mail mail.Sender
}

// Actions returns all auth actions.
func Actions(k api.Kernel, r *repo.Repo, log *logger.Logger) []api.Action {
	return BuildActions(&Service{K: k, R: r, Spaces: spacesPortBridge{K: k}, L: log.Named("auth")})
}

func BuildActions(s *Service) []api.Action {
	return append([]api.Action{
		&registerAction{s: s},
		&loginAction{s: s},
		&logoutAction{s: s},
		&sessionAction{s: s},
		&whoamiAction{s: s},
		&oauthGoogleAction{s: s},
	}, append(accountActions(s), recoveryActions(s)...)...)
}

// Account finds an account by handle or email.
func (s *Service) Account(ctx context.Context, handleOrEmail string) (*account.Account, error) {
	return s.AccountOn(ctx, handleOrEmail, "")
}

// AccountOn finds a person in one environment (empty platform = main Aseman).
func (s *Service) AccountOn(ctx context.Context, handleOrEmail, platformID string) (*account.Account, error) {
	lookup := func(equal map[string]any) (*account.Account, bool) {
		equal["platform_id"] = platformID
		var list []account.Account
		if err := s.R.List(ctx, "accounts", database.Filter{Equal: equal}, &list); err == nil && len(list) > 0 {
			return &list[0], true
		}
		// Older rows may omit platform_id; treat missing as main.
		if platformID == "" {
			delete(equal, "platform_id")
			if err := s.R.List(ctx, "accounts", database.Filter{Equal: equal}, &list); err == nil {
				for i := range list {
					if list[i].PlatformID == "" {
						return &list[i], true
					}
				}
			}
		}
		return nil, false
	}
	if acc, ok := lookup(map[string]any{"handle": handleOrEmail}); ok {
		return acc, nil
	}
	if lower := strings.ToLower(strings.TrimPrefix(strings.TrimSpace(handleOrEmail), "@")); lower != handleOrEmail {
		if acc, ok := lookup(map[string]any{"handle": lower}); ok {
			return acc, nil
		}
	}
	if acc, ok := lookup(map[string]any{"email": handleOrEmail}); ok {
		return acc, nil
	}
	return nil, errs.NotFound("account " + handleOrEmail)
}

// Login authenticates a user and issues a session token plus the caller's
// decrypted private identity key.
func (s *Service) Login(ctx context.Context, handleOrEmail, password string) (*account.Account, string, string, error) {
	return s.LoginOn(ctx, handleOrEmail, password, "")
}

// LoginOn authenticates inside one environment (empty = main Aseman).
func (s *Service) LoginOn(ctx context.Context, handleOrEmail, password, platformID string) (*account.Account, string, string, error) {
	acc, err := s.AccountOn(ctx, handleOrEmail, platformID)
	if err != nil {
		return nil, "", "", errs.Unauthenticated("invalid credentials")
	}
	if acc.Status == account.StatusDisabled {
		return nil, "", "", errs.Unauthenticated("account is disabled")
	}
	isAdmin := acc.Role == "admin" || acc.Handle == s.K.Env()["admin_handle"]
	// An administrator keeps a password way in, should the identity provider fail.
	if !isAdmin {
		if err := s.ssoRequired(ctx, acc.Email, "password"); err != nil {
			return nil, "", "", err
		}
	}
	if !isAdmin && (acc.Status == account.StatusPending || !acc.EmailVerified) {
		return nil, "", "", errs.Unauthenticated("please verify your email address before signing in")
	}
	if acc.Status != account.StatusActive && !isAdmin {
		return nil, "", "", errs.Unauthenticated("account is not active")
	}
	if err := bcrypt.CompareHashAndPassword([]byte(acc.PasswordHash), []byte(password)); err != nil {
		return nil, "", "", errs.Unauthenticated("invalid credentials")
	}
	priv, err := s.PrivateKey(ctx, acc, password)
	if err != nil {
		return nil, "", "", errs.Unauthenticated("cannot recover identity key")
	}
	if acc.RecoveryKeyEnc == "" && s.K.Env()["node_private_key"] != "" {
		if encrypted, e := crypto.EncryptPrivateKey(priv, s.K.Env()["node_private_key"]); e == nil {
			acc.RecoveryKeyEnc = encrypted
			_ = s.R.Update(ctx, "accounts", acc.ID, acc)
		}
	}
	token, err := s.IssueToken(ctx, acc.ID, session.KindSession)
	if err != nil {
		return nil, "", "", err
	}
	return acc, token, priv, nil
}

// PrivateKey decrypts the account's stored identity private key with its
// password.
func (s *Service) PrivateKey(ctx context.Context, acc *account.Account, password string) (string, error) {
	if acc.PrivateKeyEnc == "" {
		return "", errs.NotFound("no identity key on account")
	}
	priv, err := crypto.DecryptPrivateKey(acc.PrivateKeyEnc, password)
	if err != nil {
		return "", errs.Wrap(errs.CodeUnauthenticated, err, "decrypt identity key")
	}
	return priv, nil
}

// IssueToken creates a session and returns the raw bearer token.
func (s *Service) IssueToken(ctx context.Context, owner identity.ID, kind session.Kind) (string, error) {
	raw, err := idutil.RandomHex(24)
	if err != nil {
		return "", errs.Wrap(errs.CodeInternal, err, "generate token")
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return "", err
	}
	now := time.Now().UTC()
	sess := &session.Session{
		Entity:     entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		OwnerID:    owner,
		TokenHash:  HashToken(raw),
		Kind:       kind,
		ExpiresAt:  now.Add(30 * 24 * time.Hour),
		LastSeenAt: now,
	}
	if err := s.R.CreateID(ctx, "sessions", id, sess); err != nil {
		return "", err
	}
	return raw, nil
}

// HashToken hashes a raw token for storage.
func HashToken(raw string) string {
	h := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(h[:])
}

// Authenticate resolves a bearer token to an account.
func (s *Service) Authenticate(ctx context.Context, rawToken string) (*account.Account, error) {
	return helper.SessionAccount(ctx, s.R, rawToken)
}

// Register creates a user account, its metadata tree, wallet and identity
// keypair. The private key is stored encrypted with the password and returned
// once to the caller.
func (s *Service) Register(ctx context.Context, handle, email, password string) (*account.Account, string, string, error) {
	return s.RegisterOn(ctx, handle, email, password, "")
}

// RegisterOn creates an account in one environment (empty = main Aseman).
// Handles and emails are unique per environment, so the same Google identity
// can exist on main Aseman and on each sub-platform as separate local accounts.
func (s *Service) RegisterOn(ctx context.Context, handle, email, password, platformID string) (*account.Account, string, string, error) {
	if platformID != "" && handle == s.K.Env()["admin_handle"] {
		return nil, "", "", errs.InvalidArgument("the node administrator belongs to main Aseman")
	}
	if handle != s.K.Env()["admin_handle"] {
		clean, err := helper.NormalizeHandle(handle)
		if err != nil {
			return nil, "", "", err
		}
		handle = clean
	}
	if handle == "" || email == "" || len(password) < 8 {
		return nil, "", "", errs.InvalidArgument("handle, email and a password of at least 8 characters are required")
	}
	if !strings.Contains(email, "@") {
		return nil, "", "", errs.InvalidArgument("invalid email")
	}
	var existing []account.Account
	if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"handle": handle, "platform_id": platformID}}, &existing); err == nil && len(existing) > 0 {
		return nil, "", "", errs.AlreadyExists("handle " + handle)
	}
	if platformID == "" {
		if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"handle": handle}}, &existing); err == nil {
			for _, a := range existing {
				if a.PlatformID == "" {
					return nil, "", "", errs.AlreadyExists("handle " + handle)
				}
			}
		}
	}
	// Renaming the administrator must not free a handle that grants admin access.
	if handle == s.K.Env()["admin_handle"] && s.hasAdminAccount(ctx) {
		return nil, "", "", errs.AlreadyExists("bootstrap administrator handle is reserved")
	}
	if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"email": email, "platform_id": platformID}}, &existing); err == nil && len(existing) > 0 {
		return nil, "", "", errs.AlreadyExists("email " + email)
	}
	if platformID == "" {
		if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"email": email}}, &existing); err == nil {
			for _, a := range existing {
				if a.PlatformID == "" {
					return nil, "", "", errs.AlreadyExists("email " + email)
				}
			}
		}
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return nil, "", "", errs.Wrap(errs.CodeInternal, err, "hash password")
	}
	kp, err := crypto.Generate()
	if err != nil {
		return nil, "", "", errs.Wrap(errs.CodeInternal, err, "generate identity key")
	}
	encPriv, err := crypto.EncryptPrivateKey(kp.PrivateHex(), password)
	if err != nil {
		return nil, "", "", errs.Wrap(errs.CodeInternal, err, "encrypt identity key")
	}
	node := s.K.NodeID()
	accID, err := identity.New(node)
	if err != nil {
		return nil, "", "", err
	}
	now := time.Now().UTC()
	walletID, err := identity.New(node)
	if err != nil {
		return nil, "", "", err
	}
	acc := &account.Account{
		Entity:        entity.Entity{ID: accID, CreatedAt: now, UpdatedAt: now},
		Kind:          account.KindUser,
		Handle:        handle,
		Email:         email,
		PasswordHash:  string(hash),
		PublicKey:     kp.PublicHex(),
		PrivateKeyEnc: encPriv,
		Status:        account.StatusPending,
		MetadataID:    accID, // metadata keyed by owner id
		PlatformID:    platformID,
	}
	acc.Role = "user"
	if handle == s.K.Env()["admin_handle"] && platformID == "" {
		acc.Role = "admin"
		acc.Status = account.StatusActive
		acc.EmailVerified = true
	}
	if master := s.K.Env()["node_private_key"]; master != "" {
		recovery, err := crypto.EncryptPrivateKey(kp.PrivateHex(), master)
		if err != nil {
			return nil, "", "", err
		}
		acc.RecoveryKeyEnc = recovery
	}
	if err := s.R.CreateID(ctx, "accounts", accID, acc); err != nil {
		return nil, "", "", err
	}
	meta := &metadata.Record{
		Owner: accID.String(),
		// A person is named by their first and last name, else their handle:
		// nothing is written here that could go stale when the handle changes.
		Tree:        metadata.Tree{"profile": map[string]any{}},
		PublicPaths: []string{"/profile"},
		Version:     1,
		UpdatedAt:   now,
	}
	if err := s.R.CreateID(ctx, "metadatas", accID, meta); err != nil {
		return nil, "", "", err
	}
	wal := &wallet.Wallet{ID: walletID, OwnerID: accID, Balance: 0, Locked: 0, UpdatedAt: now}
	if err := s.R.CreateID(ctx, "wallets", walletID, wal); err != nil {
		return nil, "", "", err
	}
	token, err := s.IssueToken(ctx, accID, session.KindSession)
	if err != nil {
		return nil, "", "", err
	}
	return acc, token, kp.PrivateHex(), nil
}

// HomeSpaceID returns the caller's default home workspace id ("" when none).
func (s *Service) HomeSpaceID(ctx context.Context, owner identity.ID) string {
	if s.Spaces == nil {
		return ""
	}
	sp, err := s.Spaces.HomeSpace(ctx, owner)
	if err != nil {
		return ""
	}
	return sp.ID.String()
}

// Logout invalidates the given session token.
func (s *Service) Logout(ctx context.Context, rawToken string) error {
	var sessions []session.Session
	if err := s.R.List(ctx, "sessions", database.Filter{Equal: map[string]any{"token_hash": HashToken(rawToken)}}, &sessions); err != nil {
		return nil
	}
	for i := range sessions {
		_ = s.R.Delete(ctx, "sessions", sessions[i].ID)
	}
	return nil
}

// OAuthSignIn signs in or registers using verified OpenID Connect claims from
// an identity provider (google, apple). The account password is derived
// deterministically from the provider's stable subject so the identity key
// remains recoverable across sign-ins.
func (s *Service) OAuthSignIn(ctx context.Context, provider string, claims map[string]any) (*account.Account, string, string, bool, error) {
	return s.OAuthSignInOn(ctx, provider, claims, "")
}

// OAuthSignInOn is OAuthSignIn scoped to one environment (empty = main Aseman).
func (s *Service) OAuthSignInOn(ctx context.Context, provider string, claims map[string]any, platformID string) (*account.Account, string, string, bool, error) {
	email, _ := claims["email"].(string)
	sub, _ := claims["sub"].(string)
	verified, _ := claims["email_verified"].(bool)
	if email == "" || !strings.Contains(email, "@") {
		return nil, "", "", false, errs.InvalidArgument(provider + " token missing email")
	}
	if sub == "" {
		return nil, "", "", false, errs.InvalidArgument(provider + " token missing subject")
	}
	if err := s.ssoRequired(ctx, email, provider); err != nil {
		return nil, "", "", false, err
	}
	oauthPass := oauthPassword(provider, sub)
	var targetAccount *account.Account

	var list []account.Account
	if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"email": email, "platform_id": platformID}}, &list); err == nil && len(list) > 0 {
		targetAccount = &list[0]
	} else if platformID == "" {
		if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"email": email}}, &list); err == nil {
			for i := range list {
				if list[i].PlatformID == "" {
					targetAccount = &list[i]
					break
				}
			}
		}
	}
	if targetAccount == nil {
		if existing, ok := s.findAccountByOAuthOn(ctx, provider, sub, platformID); ok {
			targetAccount = existing
		}
	}

	if targetAccount != nil {
		if targetAccount.Status == account.StatusDisabled {
			return nil, "", "", false, errs.Unauthenticated("account is disabled")
		}
		// If account was pending email verification, signing in with verified OAuth activates and verifies it.
		if targetAccount.Status == account.StatusPending {
			targetAccount.Status = account.StatusActive
			targetAccount.EmailVerified = true
			targetAccount.UpdatedAt = time.Now().UTC()
			_ = s.R.Update(ctx, "accounts", targetAccount.ID, targetAccount)
		}
		priv, err := s.PrivateKey(ctx, targetAccount, oauthPass)
		link, linked := s.loadOAuthLink(ctx, targetAccount.ID)
		if err != nil {
			// Password doesn't match oauthPassword (account was created with password, another provider, or password was set/changed).
			// If provider is already linked, or email is verified by this provider, recover the private key.
			if (linked && link.Matches(provider, sub)) || verified {
				priv, err = s.recoverKey(targetAccount)
			}
		}
		if err != nil {
			return nil, "", "", false, errs.Unauthenticated("unable to sign in with provider; please sign in with your password")
		}
		// Ensure this provider & sub are linked to the account.
		if !linked || !link.Matches(provider, sub) {
			link.Link(provider, sub)
			if targetAccount.PasswordHash != "" && !linked {
				// The user originally registered with a password or already has one set.
				link.Password = true
			}
			_ = s.saveOAuthLink(ctx, targetAccount.ID, link)
		}
		token, err := s.IssueToken(ctx, targetAccount.ID, session.KindSession)
		if err != nil {
			return nil, "", "", false, err
		}
		return targetAccount, token, priv, false, nil
	}
	handle, err := s.freeHandleOn(ctx, helper.SanitizeHandle("u_"+strings.Split(email, "@")[0]), platformID)
	if err != nil {
		return nil, "", "", false, err
	}
	acc, token, priv, err := s.RegisterOn(ctx, handle, email, oauthPass, platformID)
	if err != nil {
		return nil, "", "", false, err
	}
	// OAuth signups are immediately active and verified.
	acc.Status = account.StatusActive
	acc.EmailVerified = true
	acc.UpdatedAt = time.Now().UTC()
	_ = s.R.Update(ctx, "accounts", acc.ID, acc)
	if err := s.saveOAuthLink(ctx, acc.ID, oauthLink{Provider: provider, Sub: sub}); err != nil {
		return nil, "", "", false, err
	}
	return acc, token, priv, true, nil
}

// freeHandle returns base, or base with a numeric suffix when it is taken.
func (s *Service) freeHandle(ctx context.Context, base string) (string, error) {
	return s.freeHandleOn(ctx, base, "")
}

func (s *Service) freeHandleOn(ctx context.Context, base, platformID string) (string, error) {
	for i := 0; i < 50; i++ {
		candidate := base
		if i > 0 {
			candidate = base + "_" + strconv.Itoa(i+1)
		}
		var existing []account.Account
		if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"handle": candidate, "platform_id": platformID}, Limit: 1}, &existing); err != nil {
			return "", err
		}
		taken := len(existing) > 0
		if !taken && platformID == "" {
			if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"handle": candidate}, Limit: 20}, &existing); err != nil {
				return "", err
			}
			for _, a := range existing {
				if a.PlatformID == "" {
					taken = true
					break
				}
			}
		}
		if !taken {
			return candidate, nil
		}
	}
	return "", errs.Conflict("no free handle for " + base)
}

// oauthPassword derives a stable password from a provider subject claim.
// Google keeps its original derivation so existing accounts still unlock.
func oauthPassword(provider, sub string) string {
	seed := "aseman-oauth:" + sub
	if provider != "google" {
		seed = "aseman-oauth:" + provider + ":" + sub
	}
	h := sha256.Sum256([]byte(seed))
	return "oauth-" + hex.EncodeToString(h[:])[:16]
}

func idutilMust() string { s, _ := idutil.RandomString(8); return s }

// registerAction implements auth.register.
type registerAction struct{ s *Service }

func (a *registerAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "auth", Name: "register", Summary: "Register a new user account"}
}
func (a *registerAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Handle   string `json:"handle"`
		Email    string `json:"email"`
		Password string `json:"password"`
		Platform string `json:"platform"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	platformID, err := helper.ResolvePlatformID(ctx, a.s.R, in.Platform)
	if err != nil {
		return nil, err
	}
	acc, token, priv, err := a.s.RegisterOn(ctx, in.Handle, in.Email, in.Password, platformID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"account_id": acc.ID.String(), "handle": acc.Handle, "token": token, "private_key": priv, "public_key": acc.PublicKey, "platform_id": acc.PlatformID, "home_space_id": a.s.HomeSpaceID(ctx, acc.ID)})
}

// loginAction implements auth.login.
type loginAction struct{ s *Service }

func (a *loginAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "auth", Name: "login", Summary: "Login and receive a session token"}
}
func (a *loginAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Account  string `json:"account"`
		Password string `json:"password"`
		Platform string `json:"platform"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	platformID, err := helper.ResolvePlatformID(ctx, a.s.R, in.Platform)
	if err != nil {
		return nil, err
	}
	acc, token, priv, err := a.s.LoginOn(ctx, in.Account, in.Password, platformID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"account_id": acc.ID.String(), "handle": acc.Handle, "token": token, "private_key": priv, "public_key": acc.PublicKey, "platform_id": acc.PlatformID, "home_space_id": a.s.HomeSpaceID(ctx, acc.ID)})
}

// logoutAction implements auth.logout.
type logoutAction struct{ s *Service }

func (a *logoutAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "auth", Name: "logout", Summary: "Logout (invalidate session)"}
}
func (a *logoutAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	token, _ := req.Meta["token"].(string)
	_ = a.s.Logout(ctx, token)
	return helper.JSON(map[string]any{"ok": true})
}

// sessionAction implements auth.session.
type sessionAction struct{ s *Service }

func (a *sessionAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "auth", Name: "session", Summary: "Get the current session"}
}
func (a *sessionAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	token, _ := req.Meta["token"].(string)
	acc, err := a.s.Authenticate(ctx, token)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"account_id": acc.ID.String(), "handle": acc.Handle, "kind": acc.Kind})
}

// whoamiAction implements auth.whoami.
type whoamiAction struct{ s *Service }

func (a *whoamiAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "auth", Name: "whoami", Summary: "Return the authenticated caller"}
}
func (a *whoamiAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if req.Caller.ID.IsZero() {
		return nil, errs.Unauthenticated("not authenticated")
	}
	return helper.JSON(map[string]any{"id": req.Caller.ID.String(), "kind": req.Caller.Kind})
}

// oauthGoogleAction implements auth.oauth_google.
type oauthGoogleAction struct{ s *Service }

func (a *oauthGoogleAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "auth", Name: "oauth_google", Summary: "Sign in / up with a Google id_token"}
}
func (a *oauthGoogleAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		IDToken  string `json:"id_token"`
		Platform string `json:"platform"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	platformID, err := helper.ResolvePlatformID(ctx, a.s.R, in.Platform)
	if err != nil {
		return nil, err
	}
	claims, err := crypto.VerifyGoogleIDToken(ctx, in.IDToken, a.s.K.Env()["google_client_id"])
	if err != nil {
		return nil, errs.Wrap(errs.CodeInvalidArgument, err, "invalid google token")
	}
	acc, token, priv, isNew, err := a.s.OAuthSignInOn(ctx, "google", claims, platformID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{
		"account_id": acc.ID.String(), "handle": acc.Handle,
		"token": token, "private_key": priv, "public_key": acc.PublicKey, "new": isNew,
		"platform_id": acc.PlatformID, "home_space_id": a.s.HomeSpaceID(ctx, acc.ID),
	})
}

// SpacesPort is resolved dynamically through the namespace bridge.
type SpacesPort interface {
	CreateHomeSpace(ctx context.Context, owner identity.ID, handle string) (*space.Space, error)
	HomeSpace(ctx context.Context, owner identity.ID) (*space.Space, error)
}
