package crypto

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// signedToken builds an RS256 id_token signed by key with the given claims.
func signedToken(t *testing.T, key *rsa.PrivateKey, kid string, claims map[string]any) string {
	t.Helper()
	enc := func(v any) string {
		b, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return base64.RawURLEncoding.EncodeToString(b)
	}
	head := enc(map[string]string{"alg": "RS256", "kid": kid, "typ": "JWT"})
	body := enc(claims)
	digest := sha256.Sum256([]byte(head + "." + body))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return head + "." + body + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func jwksServer(t *testing.T, key *rsa.PrivateKey, kid string) *httptest.Server {
	t.Helper()
	set := map[string]any{"keys": []map[string]string{{
		"kty": "RSA", "kid": kid, "alg": "RS256", "use": "sig",
		"n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
		"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
	}}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(set)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestVerifyIDTokenAgainstJWKS(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	srv := jwksServer(t, key, "k1")
	v := &jwksVerifier{url: srv.URL, keys: map[string]*rsa.PublicKey{}, client: srv.Client()}
	claims := map[string]any{"iss": appleIssuer, "aud": "com.example.app", "sub": "001.abc", "email": "a@example.com", "email_verified": "true", "exp": time.Now().Add(time.Hour).Unix()}

	got, err := verifyIDToken(context.Background(), v, signedToken(t, key, "k1", claims), []string{appleIssuer}, []string{"web.example", "com.example.app"})
	if err != nil {
		t.Fatalf("valid token rejected: %v", err)
	}
	if got["sub"] != "001.abc" || got["email"] != "a@example.com" || got["email_verified"] != true {
		t.Fatalf("unexpected claims: %+v", got)
	}

	if _, err := verifyIDToken(context.Background(), v, signedToken(t, key, "k1", claims), []string{appleIssuer}, []string{"other.client"}); err == nil {
		t.Fatal("token for another audience must be rejected")
	}
	expired := map[string]any{"iss": appleIssuer, "aud": "com.example.app", "sub": "x", "exp": time.Now().Add(-time.Minute).Unix()}
	if _, err := verifyIDToken(context.Background(), v, signedToken(t, key, "k1", expired), []string{appleIssuer}, []string{"com.example.app"}); err == nil {
		t.Fatal("expired token must be rejected")
	}
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	if _, err := verifyIDToken(context.Background(), v, signedToken(t, other, "k1", claims), []string{appleIssuer}, []string{"com.example.app"}); err == nil {
		t.Fatal("token signed by an unknown key must be rejected")
	}
}
