// Package signing implements request signing and verification shared by the
// user-facing API gateway and the inter-node federation surface. Requests are
// signed with Ed25519 over a canonical payload; nonces prevent replay.
package signing

import (
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/tradera/tradera/pkg/crypto"
	"github.com/tradera/tradera/pkg/errs"
)

// Signing headers.
const (
	HdrNonce     = "X-Tradera-Nonce"
	HdrTimestamp = "X-Tradera-Timestamp"
	HdrSignature = "X-Tradera-Signature"
	HdrNode      = "X-Tradera-Node"
)

// Window is the maximum accepted request age in seconds.
const Window = 300

// ReplayGuard rejects replayed signed requests.
type ReplayGuard struct {
	mu   sync.Mutex
	seen map[string]int64
}

// NewReplayGuard creates a guard.
func NewReplayGuard() *ReplayGuard {
	return &ReplayGuard{seen: map[string]int64{}}
}

// Check enforces the freshness window and uniqueness of a nonce for a key.
func (g *ReplayGuard) Check(key, nonce string, ts int64) error {
	if time.Now().Unix()-ts > Window {
		return errs.New(errs.CodeUnauthenticated, "request timestamp expired")
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	k := key + ":" + nonce
	if _, ok := g.seen[k]; ok {
		return errs.New(errs.CodeUnauthenticated, "replayed request nonce")
	}
	g.seen[k] = ts
	return nil
}

// SignRequest signs a request body with a private key and returns the three
// signature headers.
func SignRequest(privateKey, method, path string, body []byte) (map[string]string, error) {
	nonce, err := crypto.NewNonce()
	if err != nil {
		return nil, err
	}
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	payload := crypto.RequestPayload(method, path, nonce, ts, crypto.BodyHash(body))
	sig, err := crypto.SignHex(privateKey, payload)
	if err != nil {
		return nil, err
	}
	return map[string]string{
		HdrNonce:     nonce,
		HdrTimestamp: ts,
		HdrSignature: sig,
	}, nil
}

// VerifyRequest verifies a signed request against a public key and checks for
// replays. key identifies the signer in the replay guard.
func (g *ReplayGuard) VerifyRequest(publicKey, key, method, path string, headers map[string]string, body []byte) error {
	nonce := Header(headers, HdrNonce)
	ts := Header(headers, HdrTimestamp)
	sig := Header(headers, HdrSignature)
	if nonce == "" || ts == "" || sig == "" {
		return errs.Unauthenticated("signature headers required")
	}
	tsInt, err := ParseTimestamp(ts)
	if err != nil {
		return errs.Unauthenticated("invalid timestamp")
	}
	payload := crypto.RequestPayload(method, path, nonce, ts, crypto.BodyHash(body))
	if !crypto.VerifyHex(publicKey, payload, sig) {
		return errs.Unauthenticated("invalid signature")
	}
	return g.Check(key, nonce, tsInt)
}

// Header returns a header value case-insensitively.
func Header(headers map[string]string, name string) string {
	for k, v := range headers {
		if strings.EqualFold(k, name) {
			return v
		}
	}
	return ""
}

// ParseTimestamp parses an unsigned decimal unix timestamp.
func ParseTimestamp(s string) (int64, error) {
	var ts int64
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, errs.InvalidArgument("non-numeric timestamp")
		}
		ts = ts*10 + int64(c-'0')
	}
	return ts, nil
}
