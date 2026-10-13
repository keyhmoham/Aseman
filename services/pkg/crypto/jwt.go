package crypto

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"
)

const (
	googleJWKSURL = "https://www.googleapis.com/oauth2/v3/certs"
	googleIssuer  = "accounts.google.com"
	appleJWKSURL  = "https://appleid.apple.com/auth/keys"
	appleIssuer   = "https://appleid.apple.com"
)

// jwks is the Google public key set response.
type jwks struct {
	Keys []jwk `json:"keys"`
}

type jwk struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	Use string `json:"use"`
	Alg string `json:"alg"`
	N   string `json:"n"`
	E   string `json:"e"`
}

type jwtHeader struct {
	Alg string `json:"alg"`
	Kid string `json:"kid"`
	Typ string `json:"typ"`
}

// jwtClaims are the verified claims of an OpenID Connect id_token. Apple
// encodes email_verified as a string, so it is decoded loosely.
type jwtClaims struct {
	Iss           string          `json:"iss"`
	Aud           string          `json:"aud"`
	Exp           int64           `json:"exp"`
	Iat           int64           `json:"iat"`
	Sub           string          `json:"sub"`
	Email         string          `json:"email"`
	EmailVerified json.RawMessage `json:"email_verified"`
	Name          string          `json:"name"`
}

// jwksVerifier caches one identity provider's JWKS with a TTL.
type jwksVerifier struct {
	url     string
	mu      sync.Mutex
	keys    map[string]*rsa.PublicKey
	fetched time.Time
	client  *http.Client
}

var (
	defaultGoogle = &jwksVerifier{url: googleJWKSURL, keys: map[string]*rsa.PublicKey{}, client: &http.Client{Timeout: 15 * time.Second}}
	defaultApple  = &jwksVerifier{url: appleJWKSURL, keys: map[string]*rsa.PublicKey{}, client: &http.Client{Timeout: 15 * time.Second}}
)

// VerifyGoogleIDToken verifies a Google id_token (RS256, issuer, audience,
// expiry) and returns its claims. clientID can be a single OAuth client id or
// multiple comma-separated client ids (e.g. web, iOS, Android).
func VerifyGoogleIDToken(ctx context.Context, idToken, clientID string) (map[string]any, error) {
	var audiences []string
	for _, id := range strings.Split(clientID, ",") {
		if id = strings.TrimSpace(id); id != "" {
			audiences = append(audiences, id)
		}
	}
	if len(audiences) == 0 && clientID != "" {
		audiences = []string{clientID}
	}
	return verifyIDToken(ctx, defaultGoogle, idToken, []string{googleIssuer, "https://" + googleIssuer}, audiences)
}

// VerifyAppleIdentityToken verifies a Sign in with Apple identity token
// (RS256, issuer, audience, expiry) and returns its claims. audiences are the
// accepted client ids (the app bundle id and/or the web Services ID).
func VerifyAppleIdentityToken(ctx context.Context, identityToken string, audiences []string) (map[string]any, error) {
	return verifyIDToken(ctx, defaultApple, identityToken, []string{appleIssuer}, audiences)
}

func verifyIDToken(ctx context.Context, verifier *jwksVerifier, idToken string, issuers, audiences []string) (map[string]any, error) {
	parts := splitToken(idToken)
	if len(parts) != 3 {
		return nil, fmt.Errorf("malformed id_token")
	}
	headerBytes, err := decodeSegment(parts[0])
	if err != nil {
		return nil, err
	}
	payloadBytes, err := decodeSegment(parts[1])
	if err != nil {
		return nil, err
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, fmt.Errorf("bad signature encoding")
	}

	var header jwtHeader
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return nil, fmt.Errorf("bad token header")
	}
	if header.Alg != "RS256" {
		return nil, fmt.Errorf("unexpected algorithm %q", header.Alg)
	}

	key, err := verifier.key(ctx, header.Kid)
	if err != nil {
		return nil, err
	}

	// Signature is over "header.payload".
	msg := []byte(parts[0] + "." + parts[1])
	digest := sha256.Sum256(msg)
	if err := rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], sig); err != nil {
		return nil, fmt.Errorf("signature verification failed")
	}

	var claims jwtClaims
	if err := json.Unmarshal(payloadBytes, &claims); err != nil {
		return nil, fmt.Errorf("bad claims")
	}
	if !contains(issuers, claims.Iss) {
		return nil, fmt.Errorf("unexpected issuer %q", claims.Iss)
	}
	if claims.Aud == "" || !contains(audiences, claims.Aud) {
		return nil, fmt.Errorf("token audience does not match client id")
	}
	if time.Now().Unix() > claims.Exp {
		return nil, fmt.Errorf("token expired")
	}
	if claims.Sub == "" {
		return nil, fmt.Errorf("token missing subject")
	}

	return map[string]any{
		"sub":            claims.Sub,
		"email":          claims.Email,
		"email_verified": string(claims.EmailVerified) == "true" || string(claims.EmailVerified) == `"true"`,
		"name":           claims.Name,
		"iss":            claims.Iss,
		"aud":            claims.Aud,
	}, nil
}

func (g *jwksVerifier) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if k, ok := g.keys[kid]; ok && time.Since(g.fetched) < 15*time.Minute {
		return k, nil
	}
	if err := g.refresh(ctx); err != nil {
		return nil, err
	}
	k, ok := g.keys[kid]
	if !ok {
		return nil, fmt.Errorf("unknown kid %q", kid)
	}
	return k, nil
}

func (g *jwksVerifier) refresh(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, g.url, nil)
	if err != nil {
		return err
	}
	resp, err := g.client.Do(req)
	if err != nil {
		return fmt.Errorf("fetch jwks: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("jwks status %d", resp.StatusCode)
	}
	var set jwks
	if err := json.NewDecoder(resp.Body).Decode(&set); err != nil {
		return err
	}
	keys := map[string]*rsa.PublicKey{}
	for _, k := range set.Keys {
		if k.Kty != "RSA" || k.N == "" || k.E == "" {
			continue
		}
		// n is the base64url big-endian modulus (RFC 7518 §6.3.1).
		nBytes, err := base64.RawURLEncoding.DecodeString(k.N)
		if err != nil || len(nBytes) == 0 {
			continue
		}
		n := new(big.Int).SetBytes(nBytes)
		eBytes, err := base64.RawURLEncoding.DecodeString(k.E)
		if err != nil {
			continue
		}
		e := 0
		for _, b := range eBytes {
			e = e<<8 | int(b)
		}
		pub := &rsa.PublicKey{N: n, E: e}
		keys[k.Kid] = pub
	}
	g.keys = keys
	g.fetched = time.Now()
	return nil
}

func contains(list []string, v string) bool {
	for _, item := range list {
		if item != "" && item == v {
			return true
		}
	}
	return false
}

func splitToken(t string) []string {
	var parts []string
	start := 0
	for i := 0; i < len(t); i++ {
		if t[i] == '.' {
			parts = append(parts, t[start:i])
			start = i + 1
		}
	}
	parts = append(parts, t[start:])
	return parts
}

func decodeSegment(s string) ([]byte, error) {
	b, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		return nil, fmt.Errorf("bad base64 segment")
	}
	return b, nil
}

// EncodeRSAPublicKey renders an RSA public key as a PEM string (helpers for
// key distribution in tests/tooling).
func EncodeRSAPublicKey(key *rsa.PublicKey) (string, error) {
	der, err := x509.MarshalPKIXPublicKey(key)
	if err != nil {
		return "", err
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})), nil
}
