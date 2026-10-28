package enterprise

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/pkg/errs"
)

// SPIFFE workload identity. With a SPIRE deployment (deploy/spire), the
// agent runtime fetches a JWT-SVID for the node's audience and sends it with
// every call to the agent gateway (X-Aseman-SVID). The gateway checks it here
// against the trust domain's JWT bundle, on top of the turn token: a turn
// token copied out of a turn is not enough without the workload's identity.

type verified struct {
	id      string
	expires time.Time
}

var (
	svidMu    sync.Mutex
	svidCache = map[string]verified{}
)

// WorkloadRequired reports whether calls without a valid SVID are refused.
func (s *Service) WorkloadRequired(ctx context.Context) (bool, error) {
	st, _ := s.settings(ctx)
	return st.SPIFFERequired && st.SPIFFEBundleURL != "", nil
}

// VerifyWorkload checks a JWT-SVID and returns its SPIFFE ID.
func (s *Service) VerifyWorkload(ctx context.Context, svid string) (string, error) {
	sum := sha256.Sum256([]byte(svid))
	key := hex.EncodeToString(sum[:])
	svidMu.Lock()
	hit, ok := svidCache[key]
	svidMu.Unlock()
	if ok && time.Now().Before(hit.expires) {
		return hit.id, nil
	}
	st, _ := s.settings(ctx)
	if st.SPIFFEBundleURL == "" || st.SPIFFETrustDomain == "" {
		return "", errs.New(errs.CodeUnavailable, "workload identity is not set up")
	}
	audience := st.SPIFFEAudience
	if audience == "" {
		audience = "aseman"
	}
	claims, err := s.keys.verify(ctx, st.SPIFFEBundleURL, svid, audience, "")
	if err != nil {
		return "", err
	}
	sub, _ := claims["sub"].(string)
	if !strings.HasPrefix(sub, "spiffe://"+st.SPIFFETrustDomain+"/") {
		return "", errs.Unauthenticated("the workload is not of trust domain " + st.SPIFFETrustDomain)
	}
	exp, _ := claims.GetExpirationTime()
	until := time.Now().Add(time.Minute)
	if exp != nil && exp.Time.Before(until) {
		until = exp.Time
	}
	svidMu.Lock()
	svidCache[key] = verified{id: sub, expires: until}
	svidMu.Unlock()
	return sub, nil
}
