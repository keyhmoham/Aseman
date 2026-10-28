package enterprise

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/crypto"
	"github.com/aseman/aseman/pkg/errs"
	em "github.com/aseman/aseman/plugins/actions/enterprise/models"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// SSOCallbackPath is where identity providers send people back.
const SSOCallbackPath = "/sso/v1/callback"

func publicURL() string {
	u := strings.TrimRight(strings.TrimSpace(os.Getenv("ASEMAN_PUBLIC_URL")), "/")
	if u == "" {
		return "http://localhost:8080"
	}
	return u
}

func appURL() string {
	if u := strings.TrimSpace(os.Getenv("ASEMAN_APP_URL")); u != "" {
		return strings.TrimRight(u, "/")
	}
	return "http://localhost:3000"
}

// ssoRedirect is the redirect URI to register with the provider.
func ssoRedirect() string { return publicURL() + SSOCallbackPath }

// discovery is a provider's OpenID configuration.
type discovery struct {
	Issuer                string `json:"issuer"`
	AuthorizationEndpoint string `json:"authorization_endpoint"`
	TokenEndpoint         string `json:"token_endpoint"`
	JWKSURI               string `json:"jwks_uri"`
}

var (
	discoveryMu    sync.Mutex
	discoveryCache = map[string]struct {
		d  discovery
		at time.Time
	}{}
)

func (s *Service) discover(ctx context.Context, issuer string) (discovery, error) {
	issuer = strings.TrimRight(issuer, "/")
	discoveryMu.Lock()
	hit, ok := discoveryCache[issuer]
	discoveryMu.Unlock()
	if ok && time.Since(hit.at) < time.Hour {
		return hit.d, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, issuer+"/.well-known/openid-configuration", nil)
	if err != nil {
		return discovery{}, err
	}
	resp, err := s.HTTP.Do(req)
	if err != nil {
		return discovery{}, errs.Wrap(errs.CodeUnavailable, err, "identity provider")
	}
	defer resp.Body.Close()
	var d discovery
	if resp.StatusCode >= 300 || json.NewDecoder(resp.Body).Decode(&d) != nil || d.AuthorizationEndpoint == "" || d.TokenEndpoint == "" || d.JWKSURI == "" {
		return discovery{}, errs.New(errs.CodeUnavailable, "the identity provider's OpenID configuration could not be read at "+issuer)
	}
	if strings.TrimRight(d.Issuer, "/") != issuer {
		return discovery{}, errs.New(errs.CodeUnavailable, "the identity provider names another issuer: "+d.Issuer)
	}
	discoveryMu.Lock()
	discoveryCache[issuer] = struct {
		d  discovery
		at time.Time
	}{d, time.Now()}
	discoveryMu.Unlock()
	return d, nil
}

var slugRE = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,39}$`)

// SaveProvider adds or changes an SSO provider (administrators). An empty
// secret keeps the old one.
func (s *Service) SaveProvider(ctx context.Context, in em.SSOProvider, secret string) (*em.SSOProvider, error) {
	in.Slug = strings.ToLower(strings.TrimSpace(in.Slug))
	if !slugRE.MatchString(in.Slug) {
		return nil, errs.InvalidArgument("slug is 2–40 lowercase letters, digits and dashes")
	}
	if in.Issuer == "" || in.ClientID == "" {
		return nil, errs.InvalidArgument("issuer and client ID are required")
	}
	if _, err := s.discover(ctx, in.Issuer); err != nil {
		return nil, err
	}
	clean := []string{}
	for _, d := range in.Domains {
		if d = strings.ToLower(strings.TrimSpace(d)); d != "" {
			clean = append(clean, d)
		}
	}
	in.Domains = clean
	if in.GroupsClaim == "" {
		in.GroupsClaim = "groups"
	}
	var rows []em.SSOProvider
	_ = s.R.List(ctx, "sso_providers", database.Filter{Equal: map[string]any{"slug": in.Slug}, Limit: 1}, &rows)
	now := s.now().UTC()
	if len(rows) > 0 {
		in.Entity, in.UpdatedAt = rows[0].Entity, now
		if secret == "" {
			in.ClientSecret = rows[0].ClientSecret
		}
	} else {
		id, err := identity.New(s.K.NodeID())
		if err != nil {
			return nil, err
		}
		in.Entity = entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}
	}
	if secret != "" {
		sealed, err := crypto.SealSecret(secret, s.master(), "sso/"+in.Slug)
		if err != nil {
			return nil, errs.Wrap(errs.CodeInternal, err, "seal")
		}
		in.ClientSecret = sealed
	}
	var err error
	if len(rows) > 0 {
		err = s.R.Update(ctx, "sso_providers", in.ID, &in)
	} else {
		err = s.R.CreateID(ctx, "sso_providers", in.ID, &in)
	}
	return &in, err
}

func (s *Service) provider(ctx context.Context, slug string) (*em.SSOProvider, error) {
	var rows []em.SSOProvider
	if err := s.R.List(ctx, "sso_providers", database.Filter{Equal: map[string]any{"slug": slug}, Limit: 1}, &rows); err != nil || len(rows) == 0 || !rows[0].Enabled {
		return nil, errs.NotFound("single sign-on provider")
	}
	return &rows[0], nil
}

func random(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// StartSSO is the provider's sign-in URL for an email (its domain picks the
// provider) or a provider named by slug.
func (s *Service) StartSSO(ctx context.Context, email, slug, returnTo string) (string, error) {
	var p *em.SSOProvider
	var err error
	if slug != "" {
		p, err = s.provider(ctx, slug)
	} else if found, ok := s.providerFor(ctx, email); ok {
		p = found
	} else {
		return "", errs.NotFound("no single sign-on for that email's domain")
	}
	if err != nil {
		return "", err
	}
	d, err := s.discover(ctx, p.Issuer)
	if err != nil {
		return "", err
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return "", err
	}
	now := s.now().UTC()
	st := &em.SSOState{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, Provider: p.Slug, Verifier: random(48), Nonce: random(24),
		Return: safeReturn(returnTo), ExpiresAt: now.Add(10 * time.Minute)}
	if err := s.R.CreateID(ctx, "sso_states", id, st); err != nil {
		return "", err
	}
	challenge := sha256.Sum256([]byte(st.Verifier))
	q := url.Values{"client_id": {p.ClientID}, "response_type": {"code"}, "scope": {"openid email profile"},
		"redirect_uri": {ssoRedirect()}, "state": {id.String()}, "nonce": {st.Nonce},
		"code_challenge": {base64.RawURLEncoding.EncodeToString(challenge[:])}, "code_challenge_method": {"S256"}}
	if email != "" {
		q.Set("login_hint", email)
	}
	sep := "?"
	if strings.Contains(d.AuthorizationEndpoint, "?") {
		sep = "&"
	}
	return d.AuthorizationEndpoint + sep + q.Encode(), nil
}

func safeReturn(p string) string {
	if !strings.HasPrefix(p, "/") || strings.HasPrefix(p, "//") || strings.Contains(p, "\\") {
		return "/"
	}
	return p
}

// FinishSSO exchanges the code, verifies the id_token (signature, issuer,
// audience, nonce, expiry), signs the person in (creating their account on
// first sign-in), syncs their admin role from groups and joins them to their
// organization. It returns a one-time handoff id for the app.
func (s *Service) FinishSSO(ctx context.Context, stateID, code string) (string, string, error) {
	sid, err := identity.Parse(stateID)
	if err != nil {
		return "", "/", errs.InvalidArgument("invalid sign-in")
	}
	var st em.SSOState
	if err := s.R.Get(ctx, "sso_states", sid, &st); err != nil {
		return "", "/", errs.InvalidArgument("this sign-in expired; start again")
	}
	_ = s.R.Delete(ctx, "sso_states", sid)
	if !s.now().Before(st.ExpiresAt) {
		return "", st.Return, errs.InvalidArgument("this sign-in expired; start again")
	}
	p, err := s.provider(ctx, st.Provider)
	if err != nil {
		return "", st.Return, err
	}
	d, err := s.discover(ctx, p.Issuer)
	if err != nil {
		return "", st.Return, err
	}
	secret := ""
	if p.ClientSecret != "" {
		if secret, err = crypto.OpenSecret(p.ClientSecret, s.master(), "sso/"+p.Slug); err != nil {
			return "", st.Return, errs.Wrap(errs.CodeInternal, err, "open")
		}
	}
	form := url.Values{"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {ssoRedirect()},
		"client_id": {p.ClientID}, "code_verifier": {st.Verifier}}
	if secret != "" {
		form.Set("client_secret", secret)
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, d.TokenEndpoint, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := s.HTTP.Do(req)
	if err != nil {
		return "", st.Return, errs.Wrap(errs.CodeUnavailable, err, "identity provider")
	}
	defer resp.Body.Close()
	var tok struct {
		IDToken string `json:"id_token"`
		Error   string `json:"error"`
	}
	if json.NewDecoder(resp.Body).Decode(&tok) != nil || tok.IDToken == "" {
		return "", st.Return, errs.Unauthenticated("the identity provider did not sign you in: " + tok.Error)
	}
	claims, err := s.keys.verify(ctx, d.JWKSURI, tok.IDToken, p.ClientID, d.Issuer)
	if err != nil {
		return "", st.Return, err
	}
	if n, _ := claims["nonce"].(string); n != st.Nonce {
		return "", st.Return, errs.Unauthenticated("the sign-in does not match the one started")
	}
	email, _ := claims["email"].(string)
	if email == "" {
		email, _ = claims["preferred_username"].(string)
	}
	sub, _ := claims["sub"].(string)
	if !strings.Contains(email, "@") || sub == "" {
		return "", st.Return, errs.Unauthenticated("the identity provider did not say who you are (email and subject)")
	}
	if len(p.Domains) > 0 && !contains(p.Domains, domainOf(email)) {
		return "", st.Return, errs.Permission("this provider does not sign in " + domainOf(email))
	}
	acc, token, priv, _, err := s.Auth.OAuthSignIn(ctx, "sso:"+p.Slug, map[string]any{"email": email, "sub": sub, "email_verified": true,
		"name": claims["name"]})
	if err != nil {
		return "", st.Return, err
	}
	groups := stringsOf(claims[p.GroupsClaim])
	s.syncAdmin(ctx, acc.ID, groups, p.AdminGroups)
	s.joinOrganization(ctx, acc.ID, email)
	payload, _ := json.Marshal(map[string]any{"account_id": acc.ID.String(), "handle": acc.Handle, "token": token,
		"private_key": priv, "public_key": acc.PublicKey})
	hid, err := identity.New(s.K.NodeID())
	if err != nil {
		return "", st.Return, err
	}
	sealed, err := crypto.SealSecret(string(payload), s.master(), "sso/handoff/"+hid.String())
	if err != nil {
		return "", st.Return, errs.Wrap(errs.CodeInternal, err, "seal")
	}
	now := s.now().UTC()
	h := &em.SSOHandoff{Entity: entity.Entity{ID: hid, CreatedAt: now, UpdatedAt: now}, AccountID: acc.ID.String(), Sealed: sealed, ExpiresAt: now.Add(2 * time.Minute)}
	if err := s.R.CreateID(ctx, "sso_handoffs", hid, h); err != nil {
		return "", st.Return, err
	}
	return hid.String(), st.Return, nil
}

// CompleteSSO gives the app its session, once.
func (s *Service) CompleteSSO(ctx context.Context, handoff string) (map[string]any, error) {
	id, err := identity.Parse(handoff)
	if err != nil {
		return nil, errs.InvalidArgument("invalid handoff")
	}
	var h em.SSOHandoff
	if err := s.R.Get(ctx, "sso_handoffs", id, &h); err != nil {
		return nil, errs.Unauthenticated("this sign-in was already used or expired")
	}
	_ = s.R.Delete(ctx, "sso_handoffs", id)
	if !s.now().Before(h.ExpiresAt) {
		return nil, errs.Unauthenticated("this sign-in expired; start again")
	}
	raw, err := crypto.OpenSecret(h.Sealed, s.master(), "sso/handoff/"+id.String())
	if err != nil {
		return nil, errs.Wrap(errs.CodeInternal, err, "open")
	}
	var out map[string]any
	_ = json.Unmarshal([]byte(raw), &out)
	return out, nil
}

func (s *Service) serveCallback(ctx context.Context, req *network.Request) (*network.Response, error) {
	q := req.Query
	if e := q.Get("error"); e != "" {
		return redirect(appURL() + "/sso/complete?error=" + url.QueryEscape(e+": "+q.Get("error_description"))), nil
	}
	handoff, ret, err := s.FinishSSO(ctx, q.Get("state"), q.Get("code"))
	if err != nil {
		return redirect(appURL() + "/sso/complete?error=" + url.QueryEscape(err.Error())), nil
	}
	return redirect(appURL() + "/sso/complete?handoff=" + handoff + "&return=" + url.QueryEscape(ret)), nil
}

func redirect(to string) *network.Response {
	return &network.Response{Status: http.StatusFound, Header: map[string]string{"Location": to, "Cache-Control": "no-store"}}
}

func stringsOf(v any) []string {
	var out []string
	switch t := v.(type) {
	case []any:
		for _, x := range t {
			if s, ok := x.(string); ok {
				out = append(out, s)
			}
		}
	case string:
		for _, x := range strings.Split(t, ",") {
			if x = strings.TrimSpace(x); x != "" {
				out = append(out, x)
			}
		}
	}
	return out
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if strings.EqualFold(strings.TrimSpace(x), v) {
			return true
		}
	}
	return false
}
