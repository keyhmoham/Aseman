package auth

import (
	"encoding/json"
	"testing"

	"github.com/tradera/tradera/internal/plugins/api"
)

func TestOAuthAccountCanSetPasswordAndStillSignInWithProvider(t *testing.T) {
	s, _, ctx := recoveryHarness(t)
	claims := map[string]any{"email": "carol@example.com", "sub": "google-sub-1", "email_verified": true}
	acc, _, priv, created, err := s.OAuthSignIn(ctx, "google", claims)
	if err != nil || !created {
		t.Fatalf("first sign-in: created=%v err=%v", created, err)
	}

	hasPassword := func() bool {
		t.Helper()
		view, err := s.accountView(ctx, acc.ID, true)
		if err != nil {
			t.Fatal(err)
		}
		return view["has_password"].(bool)
	}
	if hasPassword() {
		t.Fatal("a provider-only account has no password of its own")
	}

	// Setting a password needs no current password on a provider-only account.
	body, _ := json.Marshal(map[string]any{"password": "carols-own-password"})
	req := &api.ActionRequest{Caller: api.Caller{ID: acc.ID, Kind: "user"}, Body: body}
	if _, err := s.profileUpdate(ctx, req); err != nil {
		t.Fatalf("set password: %v", err)
	}
	if !hasPassword() {
		t.Fatal("has_password must be true once the owner set one")
	}

	// The provider still signs the account in, onto the same identity key.
	_, _, again, created, err := s.OAuthSignIn(ctx, "google", claims)
	if err != nil || created {
		t.Fatalf("provider sign-in after password: created=%v err=%v", created, err)
	}
	if again != priv {
		t.Fatal("the identity key must survive the password change")
	}

	// An unverified email claim from a provider cannot sign into the account.
	unverified := map[string]any{"email": "carol@example.com", "sub": "someone-else", "email_verified": false}
	if _, _, _, _, err := s.OAuthSignIn(ctx, "google", unverified); err == nil {
		t.Fatal("an unverified provider email must not sign in")
	}

	// But a verified claim from another provider (e.g. Apple) links and signs in smoothly!
	appleClaims := map[string]any{"email": "carol@example.com", "sub": "apple-sub-1", "email_verified": true}
	_, _, applePriv, appleCreated, err := s.OAuthSignIn(ctx, "apple", appleClaims)
	if err != nil || appleCreated {
		t.Fatalf("apple sign-in: created=%v err=%v", appleCreated, err)
	}
	if applePriv != priv {
		t.Fatal("apple sign-in must yield the exact same identity key")
	}
}

func TestPasswordAccountCanLinkOAuthProviders(t *testing.T) {
	s, _, ctx := recoveryHarness(t)

	// 1. User signs up with email & password.
	rawPass := "secure-master-password"
	acc, _, priv, err := s.Register(ctx, "dave", "dave@example.com", rawPass)
	if err != nil {
		t.Fatalf("register: %v", err)
	}

	// 2. User signs in with Google (verified email) -> automatically links & recovers key.
	googleClaims := map[string]any{"email": "dave@example.com", "sub": "google-dave-1", "email_verified": true}
	gAcc, _, gPriv, gCreated, err := s.OAuthSignIn(ctx, "google", googleClaims)
	if err != nil || gCreated {
		t.Fatalf("google signin: created=%v err=%v", gCreated, err)
	}
	if gAcc.ID != acc.ID {
		t.Fatal("google signin must resolve to original account")
	}
	if gPriv != priv {
		t.Fatal("google signin must recover original identity key")
	}

	// 3. User signs in with Apple (verified email) -> links Apple as well.
	appleClaims := map[string]any{"email": "dave@example.com", "sub": "apple-dave-1", "email_verified": true}
	aAcc, _, aPriv, aCreated, err := s.OAuthSignIn(ctx, "apple", appleClaims)
	if err != nil || aCreated {
		t.Fatalf("apple signin: created=%v err=%v", aCreated, err)
	}
	if aAcc.ID != acc.ID {
		t.Fatal("apple signin must resolve to original account")
	}
	if aPriv != priv {
		t.Fatal("apple signin must recover original identity key")
	}

	// 4. User can still sign in with their original password.
	loginAcc, _, loginPriv, err := s.Login(ctx, "dave@example.com", rawPass)
	if err != nil {
		t.Fatalf("password login: %v", err)
	}
	if loginAcc.ID != acc.ID {
		t.Fatal("password login must resolve to original account")
	}
	if loginPriv != priv {
		t.Fatal("password login must return original private key")
	}

	// 5. Account profile view must still report has_password = true.
	view, err := s.accountView(ctx, acc.ID, true)
	if err != nil {
		t.Fatalf("accountView: %v", err)
	}
	if hasPass, ok := view["has_password"].(bool); !ok || !hasPass {
		t.Fatalf("expected has_password to be true, got %v", view["has_password"])
	}
}

func TestOAuthRemainsAttachedWhenEmailChanges(t *testing.T) {
	s, _, ctx := recoveryHarness(t)

	// Register with google
	claims := map[string]any{"email": "original@example.com", "sub": "google-sub-456", "email_verified": true}
	acc, _, priv, isNew, err := s.OAuthSignIn(ctx, "google", claims)
	if err != nil || !isNew {
		t.Fatalf("OAuthSignIn failed: isNew=%v err=%v", isNew, err)
	}

	// Change email in database
	acc.Email = "changed@example.com"
	if err := s.R.Update(ctx, "accounts", acc.ID, acc); err != nil {
		t.Fatalf("update email failed: %v", err)
	}

	// Sign in again with same google sub (even if google claims still have original or new email)
	loginClaims := map[string]any{"email": "original@example.com", "sub": "google-sub-456", "email_verified": true}
	againAcc, _, againPriv, againNew, err := s.OAuthSignIn(ctx, "google", loginClaims)
	if err != nil || againNew {
		t.Fatalf("OAuthSignIn after email change failed: new=%v err=%v", againNew, err)
	}
	if againAcc.ID != acc.ID {
		t.Fatalf("expected resolved account %v, got %v", acc.ID, againAcc.ID)
	}
	if againPriv != priv {
		t.Fatalf("private key did not match recovered key")
	}
}
