package enterprise

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"io"
	"math/big"
	"net/http"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/aseman/aseman/pkg/errs"
)

// keySets caches JSON Web Key Sets by address: an identity provider's, or a
// SPIFFE trust domain's JWT bundle. RSA and EC keys are both read.
type keySets struct {
	client *http.Client
	mu     sync.Mutex
	sets   map[string]*keySet
}

type keySet struct {
	keys    map[string]any
	fetched time.Time
}

func newKeySets(client *http.Client) *keySets {
	return &keySets{client: client, sets: map[string]*keySet{}}
}

// key finds a key by id, refetching the set when it is old or the id is new
// (keys rotate).
func (k *keySets) key(ctx context.Context, url, kid string) (any, error) {
	k.mu.Lock()
	set := k.sets[url]
	k.mu.Unlock()
	if set != nil && time.Since(set.fetched) < time.Hour {
		if key, ok := set.keys[kid]; ok {
			return key, nil
		}
	}
	fresh, err := k.fetch(ctx, url)
	if err != nil {
		return nil, err
	}
	k.mu.Lock()
	k.sets[url] = fresh
	k.mu.Unlock()
	if key, ok := fresh.keys[kid]; ok {
		return key, nil
	}
	// A set with one key and a token without a kid (SPIRE's) uses that key.
	if kid == "" && len(fresh.keys) == 1 {
		for _, key := range fresh.keys {
			return key, nil
		}
	}
	return nil, errs.Unauthenticated("unknown signing key")
}

func (k *keySets) fetch(ctx context.Context, url string) (*keySet, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := k.client.Do(req)
	if err != nil {
		return nil, errs.Wrap(errs.CodeUnavailable, err, "key set")
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return nil, errs.New(errs.CodeUnavailable, "key set: "+resp.Status)
	}
	var doc struct {
		Keys []struct {
			Kid string `json:"kid"`
			Kty string `json:"kty"`
			Use string `json:"use"`
			N   string `json:"n"`
			E   string `json:"e"`
			Crv string `json:"crv"`
			X   string `json:"x"`
			Y   string `json:"y"`
		} `json:"keys"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&doc); err != nil {
		return nil, errs.Wrap(errs.CodeUnavailable, err, "key set")
	}
	set := &keySet{keys: map[string]any{}, fetched: time.Now()}
	b64 := func(s string) *big.Int {
		raw, err := base64.RawURLEncoding.DecodeString(s)
		if err != nil {
			return nil
		}
		return new(big.Int).SetBytes(raw)
	}
	for _, j := range doc.Keys {
		if j.Use != "" && j.Use != "sig" && j.Use != "jwt-svid" {
			continue
		}
		switch j.Kty {
		case "RSA":
			n, e := b64(j.N), b64(j.E)
			if n != nil && e != nil {
				set.keys[j.Kid] = &rsa.PublicKey{N: n, E: int(e.Int64())}
			}
		case "EC":
			var curve elliptic.Curve
			switch j.Crv {
			case "P-256":
				curve = elliptic.P256()
			case "P-384":
				curve = elliptic.P384()
			default:
				continue
			}
			x, y := b64(j.X), b64(j.Y)
			if x != nil && y != nil {
				set.keys[j.Kid] = &ecdsa.PublicKey{Curve: curve, X: x, Y: y}
			}
		}
	}
	return set, nil
}

// verify checks a token's signature against the set, and its audience,
// issuer (when given) and expiry; it returns its claims.
func (k *keySets) verify(ctx context.Context, url, raw string, audience, issuer string) (jwt.MapClaims, error) {
	opts := []jwt.ParserOption{jwt.WithValidMethods([]string{"RS256", "RS384", "RS512", "ES256", "ES384", "PS256"}),
		jwt.WithExpirationRequired(), jwt.WithLeeway(2 * time.Minute)}
	if audience != "" {
		opts = append(opts, jwt.WithAudience(audience))
	}
	if issuer != "" {
		opts = append(opts, jwt.WithIssuer(issuer))
	}
	claims := jwt.MapClaims{}
	_, err := jwt.ParseWithClaims(raw, claims, func(t *jwt.Token) (any, error) {
		kid, _ := t.Header["kid"].(string)
		return k.key(ctx, url, kid)
	}, opts...)
	if err != nil {
		return nil, errs.Wrap(errs.CodeUnauthenticated, err, "token")
	}
	return claims, nil
}
