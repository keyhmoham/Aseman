package enterprise

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	em "github.com/aseman/aseman/plugins/actions/enterprise/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/invitation"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

// fakeAuth stands in for the auth namespace over the same database.
type fakeAuth struct {
	mu       sync.Mutex
	r        *repo.Repo
	signins  []string
	sessions int
	roles    map[string]string
}

func (f *fakeAuth) OAuthSignIn(ctx context.Context, provider string, claims map[string]any) (*account.Account, string, string, bool, error) {
	f.mu.Lock()
	f.signins = append(f.signins, provider+" "+claims["email"].(string))
	f.mu.Unlock()
	id, _ := identity.New(1)
	acc := &account.Account{Entity: entity.Entity{ID: id}, Kind: account.KindUser, Handle: "dana", Email: claims["email"].(string), Status: account.StatusActive}
	return acc, "session-token", "private-key", true, f.r.CreateID(ctx, "accounts", id, acc)
}

func (f *fakeAuth) CreateManagedAccount(ctx context.Context, handle, email, password string) (*account.Account, error) {
	id, _ := identity.New(1)
	acc := &account.Account{Entity: entity.Entity{ID: id}, Kind: account.KindUser, Handle: handle, Email: email, Status: account.StatusActive}
	return acc, f.r.CreateID(ctx, "accounts", id, acc)
}

func (f *fakeAuth) RevokeSessions(context.Context, identity.ID) (int, error) {
	f.sessions++
	return 2, nil
}

func (f *fakeAuth) SetAccess(ctx context.Context, id identity.ID, status account.Status, role string) (*account.Account, error) {
	var acc account.Account
	if err := f.r.Get(ctx, "accounts", id, &acc); err != nil {
		return nil, err
	}
	if status != "" {
		acc.Status = status
	}
	if role != "" {
		acc.Role = role
		f.mu.Lock()
		f.roles[id.String()] = role
		f.mu.Unlock()
	}
	return &acc, f.r.Update(ctx, "accounts", id, &acc)
}

type fakeSpaces struct{ stopped, joined int }

func (f *fakeSpaces) GetSpace(context.Context, identity.ID) (*space.Space, error) {
	owner, _ := identity.Parse("00000000000000010000000000000009")
	return &space.Space{OwnerID: owner}, nil
}
func (f *fakeSpaces) Invite(context.Context, identity.ID, identity.ID, identity.ID, identity.ID, membership.Role) (*invitation.Invitation, error) {
	id, _ := identity.New(1)
	return &invitation.Invitation{Entity: entity.Entity{ID: id}}, nil
}
func (f *fakeSpaces) AcceptInvitation(context.Context, identity.ID, identity.ID) error {
	f.joined++
	return nil
}
func (f *fakeSpaces) SandboxStop(context.Context, identity.ID) (map[string]any, error) {
	f.stopped++
	return map[string]any{}, nil
}

type fakeRevoker struct{ revoked []string }

func (f *fakeRevoker) Revoke(_ context.Context, id identity.ID) []string {
	f.revoked = append(f.revoked, id.String())
	return []string{"credentials revoked: 1"}
}

func harness(t *testing.T) (*Service, *fakeAuth, *fakeSpaces, *fakeRevoker, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range append(dbmodel.Models(), em.Models()...) {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"node_private_key": strings.Repeat("34", 64)}})
	r := &repo.Repo{DB: db}
	s := NewService(k, r, logger.Global())
	auth, spaces, revoker := &fakeAuth{r: r, roles: map[string]string{}}, &fakeSpaces{}, &fakeRevoker{}
	s.Auth, s.Spaces, s.Revoker = auth, spaces, revoker
	return s, auth, spaces, revoker, ctx
}

// fakeIdP is an OpenID Connect provider that signs whatever nonce it is told.
type fakeIdP struct {
	key   *rsa.PrivateKey
	url   string
	nonce string
}

func (f *fakeIdP) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/.well-known/openid-configuration":
		_ = json.NewEncoder(w).Encode(map[string]string{"issuer": f.url, "authorization_endpoint": f.url + "/authorize",
			"token_endpoint": f.url + "/token", "jwks_uri": f.url + "/jwks"})
	case "/jwks":
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{"kty": "RSA", "kid": "idp", "use": "sig",
			"n": base64.RawURLEncoding.EncodeToString(f.key.N.Bytes()), "e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(f.key.E)).Bytes())}}})
	case "/token":
		_ = r.ParseForm()
		if r.Form.Get("code_verifier") == "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		tok := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{"iss": f.url, "aud": "client-1", "sub": "idp-42",
			"email": "dana@acme.example", "nonce": f.nonce, "groups": []string{"engineering", "aseman-admins"},
			"exp": time.Now().Add(time.Hour).Unix()})
		tok.Header["kid"] = "idp"
		raw, _ := tok.SignedString(f.key)
		_ = json.NewEncoder(w).Encode(map[string]string{"id_token": raw})
	}
}

func TestSingleSignOn(t *testing.T) {
	s, auth, spaces, _, ctx := harness(t)
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	idp := &fakeIdP{key: key}
	srv := httptest.NewServer(idp)
	defer srv.Close()
	idp.url = srv.URL
	org := em.Organization{Name: "Acme", Domains: []string{"acme.example"}, SpaceID: "00000000000000010000000000000040"}
	oid, _ := identity.New(1)
	org.Entity = entity.Entity{ID: oid}
	_ = s.R.CreateID(ctx, "organizations", oid, &org)
	if _, err := s.SaveProvider(ctx, em.SSOProvider{Slug: "acme", Name: "Acme Okta", Issuer: srv.URL, ClientID: "client-1",
		Domains: []string{"acme.example"}, Required: true, AdminGroups: []string{"aseman-admins"}, Enabled: true}, "client-secret"); err != nil {
		t.Fatal(err)
	}
	if name, _ := s.RequiredProvider(ctx, "dana@ACME.example"); name != "Acme Okta" {
		t.Fatalf("the domain must sign in with SSO: %q", name)
	}
	start, err := s.StartSSO(ctx, "dana@acme.example", "", "/tasks")
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(start)
	if u.Query().Get("code_challenge_method") != "S256" || u.Query().Get("login_hint") != "dana@acme.example" {
		t.Fatalf("PKCE and a login hint: %s", start)
	}
	// A token signed for another sign-in's nonce is refused.
	idp.nonce = "someone-else"
	if _, _, err := s.FinishSSO(ctx, u.Query().Get("state"), "code"); err == nil {
		t.Fatal("a mismatched nonce must be refused")
	}
	start, _ = s.StartSSO(ctx, "dana@acme.example", "", "/tasks")
	u, _ = url.Parse(start)
	idp.nonce = u.Query().Get("nonce")
	handoff, ret, err := s.FinishSSO(ctx, u.Query().Get("state"), "code")
	if err != nil || ret != "/tasks" {
		t.Fatalf("%q %v", ret, err)
	}
	if len(auth.signins) != 1 || auth.signins[0] != "sso:acme dana@acme.example" {
		t.Fatalf("%v", auth.signins)
	}
	out, err := s.CompleteSSO(ctx, handoff)
	if err != nil || out["token"] != "session-token" || out["private_key"] != "private-key" {
		t.Fatalf("%v %v", out, err)
	}
	if _, err := s.CompleteSSO(ctx, handoff); err == nil {
		t.Fatal("a handoff is picked up once")
	}
	if spaces.joined != 1 {
		t.Fatal("the person joins their organization's project")
	}
	found := false
	for _, role := range auth.roles {
		found = found || role == "admin"
	}
	if !found {
		t.Fatal("an admin group makes an administrator")
	}
}

func scim(s *Service, ctx context.Context, method network.Method, path, token string, body any) *network.Response {
	raw, _ := json.Marshal(body)
	h := map[string]string{"Authorization": "Bearer " + token}
	parts := strings.Split(strings.TrimPrefix(path, SCIMPrefix+"/"), "/")
	if len(parts) == 2 {
		params, _ := json.Marshal(map[string]string{"id": parts[1]})
		h["x-route-params"] = string(params)
	}
	req := &network.Request{Method: method, Header: h, Body: raw, Query: url.Values{}}
	for _, r := range s.scimRoutes() {
		pattern := strings.Replace(r.path, "{id}", "", 1)
		if r.method == method && (r.path == path || (strings.HasSuffix(r.path, "{id}") && strings.HasPrefix(path, pattern) && len(parts) == 2)) {
			resp, _ := r.handler(ctx, req)
			return resp
		}
	}
	return nil
}

func TestSCIMProvisionsAndDeprovisions(t *testing.T) {
	s, auth, spaces, revoker, ctx := harness(t)
	if resp := scim(s, ctx, network.MethodGet, SCIMPrefix+"/Users", "nope", nil); resp.Status != http.StatusUnauthorized {
		t.Fatal("a SCIM call without the token is refused")
	}
	token, _ := s.NewSCIMToken(ctx)
	st, exists := s.settings(ctx)
	st.SCIMAdminGroups = []string{"IT"}
	_ = s.saveSettings(ctx, st, exists)
	resp := scim(s, ctx, network.MethodPost, SCIMPrefix+"/Users", token, map[string]any{"userName": "lee@acme.example",
		"emails": []map[string]any{{"value": "lee@acme.example", "primary": true}}, "active": true})
	if resp.Status != http.StatusCreated {
		t.Fatalf("%d %s", resp.Status, resp.Body)
	}
	var user map[string]any
	_ = json.Unmarshal(resp.Body, &user)
	id := user["id"].(string)
	resp = scim(s, ctx, network.MethodPost, SCIMPrefix+"/Groups", token, map[string]any{"displayName": "IT", "members": []map[string]string{{"value": id}}})
	if resp.Status != http.StatusCreated || auth.roles[id] != "admin" {
		t.Fatalf("a directory admin group makes an administrator: %d %v", resp.Status, auth.roles)
	}
	// The person owns a project alone: deactivating stops its computer.
	pid, _ := identity.Parse(id)
	sid, _ := identity.New(1)
	_ = s.R.CreateID(ctx, "spaces", sid, &space.Space{Entity: entity.Entity{ID: sid}, OwnerID: pid})
	resp = scim(s, ctx, network.MethodPatch, SCIMPrefix+"/Users/"+id, token, map[string]any{"Operations": []map[string]any{{"op": "replace", "path": "active", "value": false}}})
	if resp.Status != http.StatusOK || auth.sessions != 1 || len(revoker.revoked) != 1 || spaces.stopped != 1 {
		t.Fatalf("deprovisioning: %d sessions=%d revoked=%v stopped=%d", resp.Status, auth.sessions, revoker.revoked, spaces.stopped)
	}
	var acc account.Account
	_ = s.R.Get(ctx, "accounts", pid, &acc)
	if acc.Status != account.StatusDisabled {
		t.Fatal("the account is disabled")
	}
	resp = scim(s, ctx, network.MethodPatch, SCIMPrefix+"/Users/"+id, token, map[string]any{"Operations": []map[string]any{{"op": "replace", "value": map[string]any{"active": true}}}})
	_ = s.R.Get(ctx, "accounts", pid, &acc)
	if resp.Status != http.StatusOK || acc.Status != account.StatusActive {
		t.Fatal("the directory reactivates what it deactivated")
	}
}

func TestWorkloadIdentity(t *testing.T) {
	s, _, _, _, ctx := harness(t)
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	bundle := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{"kty": "EC", "crv": "P-256", "kid": "spire", "use": "jwt-svid",
			"x": base64.RawURLEncoding.EncodeToString(key.X.FillBytes(make([]byte, 32))), "y": base64.RawURLEncoding.EncodeToString(key.Y.FillBytes(make([]byte, 32)))}}})
	}))
	defer bundle.Close()
	st, exists := s.settings(ctx)
	st.SPIFFETrustDomain, st.SPIFFEBundleURL, st.SPIFFEAudience, st.SPIFFERequired = "acme.example", bundle.URL, "aseman", true
	_ = s.saveSettings(ctx, st, exists)
	svid := func(sub string) string {
		tok := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{"sub": sub, "aud": "aseman", "exp": time.Now().Add(5 * time.Minute).Unix()})
		tok.Header["kid"] = "spire"
		raw, _ := tok.SignedString(key)
		return raw
	}
	if id, err := s.VerifyWorkload(ctx, svid("spiffe://acme.example/agent-runtime")); err != nil || id != "spiffe://acme.example/agent-runtime" {
		t.Fatalf("%q %v", id, err)
	}
	if _, err := s.VerifyWorkload(ctx, svid("spiffe://evil.example/agent-runtime")); err == nil {
		t.Fatal("another trust domain is refused")
	}
	if required, _ := s.WorkloadRequired(ctx); !required {
		t.Fatal("required")
	}
}
