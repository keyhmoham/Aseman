package google

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/crypto"
	"github.com/aseman/aseman/pkg/errs"
	gm "github.com/aseman/aseman/plugins/actions/google/models"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// CallbackPath is where Google sends people back after they consent.
const CallbackPath = "/google/v1/oauth/callback"

// redirectURI is the callback on the node's public address, which must be
// registered on the OAuth client exactly.
func redirectURI() string {
	public := strings.TrimRight(strings.TrimSpace(os.Getenv("ASEMAN_PUBLIC_URL")), "/")
	if public == "" {
		public = "http://localhost:8080"
	}
	return public + CallbackPath
}

// appURL is where a person lands after connecting (the web client).
func appURL() string {
	if u := strings.TrimSpace(os.Getenv("ASEMAN_APP_URL")); u != "" {
		return strings.TrimRight(u, "/")
	}
	return "http://localhost:3000"
}

func randomURLSafe(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// StartConnect begins a person's consent: the URL to send them to.
func (s *Service) StartConnect(ctx context.Context, accountID identity.ID, returnTo string) (string, error) {
	st, _, err := s.settings(ctx)
	if err != nil {
		return "", err
	}
	if !st.Enabled {
		return "", errs.New(errs.CodeUnavailable, "Google is turned off on this node")
	}
	verifier, err := randomURLSafe(48)
	if err != nil {
		return "", err
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return "", err
	}
	now := s.now().UTC()
	state := &gm.OAuthState{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, AccountID: accountID.String(),
		Verifier: verifier, Return: safeReturn(returnTo), ExpiresAt: now.Add(10 * time.Minute)}
	if err := s.R.CreateID(ctx, "google_oauth_states", id, state); err != nil {
		return "", err
	}
	challenge := sha256.Sum256([]byte(verifier))
	q := url.Values{
		"client_id": {st.ClientID}, "redirect_uri": {redirectURI()}, "response_type": {"code"},
		"scope": {strings.Join(Scopes, " ")}, "access_type": {"offline"}, "prompt": {"consent"},
		"include_granted_scopes": {"true"}, "state": {id.String()},
		"code_challenge": {base64.RawURLEncoding.EncodeToString(challenge[:])}, "code_challenge_method": {"S256"},
	}
	return s.endpoints().Auth + "?" + q.Encode(), nil
}

// safeReturn keeps only a path within the app as where to land.
func safeReturn(p string) string {
	p = strings.TrimSpace(p)
	if !strings.HasPrefix(p, "/") || strings.HasPrefix(p, "//") || strings.Contains(p, "\\") {
		return "/"
	}
	return p
}

// FinishConnect exchanges the code Google returned for the person's tokens.
func (s *Service) FinishConnect(ctx context.Context, stateID, code string) (*gm.Connection, string, error) {
	sid, err := identity.Parse(stateID)
	if err != nil {
		return nil, "", errs.InvalidArgument("invalid state")
	}
	var state gm.OAuthState
	if err := s.R.Get(ctx, "google_oauth_states", sid, &state); err != nil {
		return nil, "", errs.InvalidArgument("this sign-in expired; start again")
	}
	// A state is used once.
	_ = s.R.Delete(ctx, "google_oauth_states", sid)
	if !s.now().Before(state.ExpiresAt) {
		return nil, "", errs.InvalidArgument("this sign-in expired; start again")
	}
	st, secret, err := s.settings(ctx)
	if err != nil {
		return nil, "", err
	}
	form := url.Values{"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {redirectURI()},
		"client_id": {st.ClientID}, "client_secret": {secret}, "code_verifier": {state.Verifier}}
	var tok struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int64  `json:"expires_in"`
		Scope        string `json:"scope"`
	}
	if err := s.postForm(ctx, s.endpoints().Token, form, &tok); err != nil {
		return nil, state.Return, err
	}
	if tok.RefreshToken == "" {
		return nil, state.Return, errs.InvalidArgument("Google did not grant offline access; remove Aseman under your Google account's third-party access and connect again")
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, s.endpoints().UserInfo, nil)
	req.Header.Set("Authorization", "Bearer "+tok.AccessToken)
	var who struct {
		Email string `json:"email"`
	}
	if err := s.do(req, &who); err != nil {
		return nil, state.Return, err
	}
	account, _ := identity.Parse(state.AccountID)
	sealed, err := crypto.SealSecret(tok.RefreshToken, s.master(), "google/refresh/"+state.AccountID)
	if err != nil {
		return nil, state.Return, errs.Wrap(errs.CodeInternal, err, "seal Google token")
	}
	now := s.now().UTC()
	c := &gm.Connection{Entity: entity.Entity{ID: account, CreatedAt: now, UpdatedAt: now}, Email: who.Email,
		Scopes: strings.Fields(tok.Scope), RefreshToken: sealed, Status: gm.StatusConnected, ConnectedAt: now, Fake: s.endpoints().Fake}
	var old gm.Connection
	if s.R.Get(ctx, "google_connections", account, &old) == nil {
		c.CreatedAt = old.CreatedAt
		err = s.R.Update(ctx, "google_connections", account, c)
	} else {
		err = s.R.CreateID(ctx, "google_connections", account, c)
	}
	if err != nil {
		return nil, state.Return, err
	}
	s.mu.Lock()
	s.tokens[state.AccountID] = accessToken{value: tok.AccessToken, expires: now.Add(time.Duration(max(tok.ExpiresIn, 60)) * time.Second)}
	s.mu.Unlock()
	s.addAppHome(ctx, account)
	return c, state.Return, nil
}

// addAppHome adds the Google app to the person's home project once they
// connect, so their own assistant can use it at once; other projects add it
// from Apps like any app. Best effort.
func (s *Service) addAppHome(ctx context.Context, account identity.ID) {
	bot := s.AppBot(ctx)
	if bot == "" || s.K == nil || s.K.Actions() == nil {
		return
	}
	var spaces []struct {
		ID string `json:"id"`
	}
	if err := s.R.List(ctx, "spaces", database.Filter{Equal: map[string]any{"owner_id": account.String(), "home": true}, Limit: 1}, &spaces); err != nil || len(spaces) == 0 {
		return
	}
	body, _ := json.Marshal(map[string]any{"space": spaces[0].ID, "bot": bot})
	if _, err := s.K.Actions().Dispatch(ctx, "spaces", "bot_add", &api.ActionRequest{Caller: api.Caller{ID: account, Kind: "user"}, Body: body}); err != nil &&
		errs.CodeOf(err) != errs.CodeAlreadyExists && errs.CodeOf(err) != errs.CodeConflict && s.L != nil {
		s.L.Warn("add the Google app to the home project", "error", err)
	}
}

// serveCallback finishes a consent in the browser and sends the person back
// to the app.
func (s *Service) serveCallback(ctx context.Context, req *network.Request) (*network.Response, error) {
	q := req.Query
	target := appURL()
	if e := q.Get("error"); e != "" {
		return redirect(target + "/?google=" + url.QueryEscape("refused: "+e)), nil
	}
	_, ret, err := s.FinishConnect(ctx, q.Get("state"), q.Get("code"))
	if ret == "" {
		ret = "/"
	}
	sep := "?"
	if strings.Contains(ret, "?") {
		sep = "&"
	}
	if err != nil {
		return redirect(target + ret + sep + "google=" + url.QueryEscape("failed: "+err.Error())), nil
	}
	return redirect(target + ret + sep + "google=connected"), nil
}

func redirect(to string) *network.Response {
	return &network.Response{Status: http.StatusFound, Header: map[string]string{"Location": to, "Cache-Control": "no-store"}}
}
