// Package google connects each person's own Gmail and Google Calendar.
//
// An administrator registers one OAuth client for the node; each person then
// connects their own account (authorization code with PKCE, offline access).
// The refresh token is sealed and never leaves the node. Agents read mail and
// the calendar through governed tools (gmail_search, gmail_read,
// calendar_events), draft freely, and send or invite only after the person
// approves (the governance gate asks before gmail_send and calendar_create).
// Other namespaces (the morning brief, triage, responsibilities) use the same
// service through the bridge, as the person.
package google

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/crypto"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	gm "github.com/aseman/aseman/plugins/actions/google/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
)

// Scopes a person grants: who they are, their mail (read, draft, send) and
// their calendar's events.
var Scopes = []string{"openid", "email",
	"https://www.googleapis.com/auth/gmail.modify",
	"https://www.googleapis.com/auth/calendar.events"}

// endpoints are Google's, or the fake Google's in tests and demos.
type endpoints struct {
	Auth, Token, Gmail, Calendar, UserInfo string
	Fake                                   bool
}

// FakeURL is the test Google's address (cmd/fakegoogle), ignored in production.
func FakeURL() string {
	if strings.EqualFold(os.Getenv("ASEMAN_ENV"), "production") {
		return ""
	}
	return strings.TrimRight(strings.TrimSpace(os.Getenv("ASEMAN_FAKE_GOOGLE_URL")), "/")
}

func currentEndpoints() endpoints {
	if u := FakeURL(); u != "" {
		return endpoints{Auth: u + "/o/oauth2/v2/auth", Token: u + "/token", Gmail: u + "/gmail/v1", Calendar: u + "/calendar/v3",
			UserInfo: u + "/oauth2/v3/userinfo", Fake: true}
	}
	return endpoints{Auth: "https://accounts.google.com/o/oauth2/v2/auth", Token: "https://oauth2.googleapis.com/token",
		Gmail: "https://gmail.googleapis.com/gmail/v1", Calendar: "https://www.googleapis.com/calendar/v3",
		UserInfo: "https://openidconnect.googleapis.com/v1/userinfo"}
}

// Service is the google namespace.
type Service struct {
	K    api.Kernel
	R    *repo.Repo
	L    *logger.Logger
	HTTP *http.Client
	now  func() time.Time
	// ep is fixed in tests; otherwise read on each use.
	ep *endpoints

	// Register lists the Google app in the catalog (tools.mcp_register when nil).
	Register AppRegistrar
	// listedCheck replaces the catalog lookup in tests.
	listedCheck func(bot string) bool

	mu     sync.Mutex
	tokens map[string]accessToken
}

type accessToken struct {
	value   string
	expires time.Time
}

// NewService builds the namespace's service.
func NewService(k api.Kernel, r *repo.Repo, log *logger.Logger) *Service {
	return &Service{K: k, R: r, L: log.Named("google"), HTTP: &http.Client{Timeout: 30 * time.Second}, now: time.Now,
		tokens: map[string]accessToken{}}
}

func (s *Service) endpoints() endpoints {
	if s.ep != nil {
		return *s.ep
	}
	return currentEndpoints()
}

func (s *Service) master() string { return s.K.Env()["node_private_key"] }

// settings is the node's OAuth client (its secret opened).
func (s *Service) settings(ctx context.Context) (gm.Settings, string, error) {
	var st gm.Settings
	id, _ := identity.Parse(gm.SettingsID)
	if err := s.R.Get(ctx, "google_settings", id, &st); err != nil {
		if errs.CodeOf(err) == errs.CodeNotFound {
			return gm.Settings{}, "", errs.New(errs.CodeUnavailable, "Google is not set up on this node: an administrator sets up the Google app under Admin → Catalog → Connector apps")
		}
		return gm.Settings{}, "", err
	}
	secret := ""
	if st.ClientSecret != "" {
		var err error
		if secret, err = crypto.OpenSecret(st.ClientSecret, s.master(), "google/client"); err != nil {
			return gm.Settings{}, "", errs.Wrap(errs.CodeInternal, err, "open Google client secret")
		}
	}
	return st, secret, nil
}

// SaveSettings stores the node's OAuth client. An empty secret keeps the old.
func (s *Service) SaveSettings(ctx context.Context, by identity.ID, enabled bool, clientID, clientSecret string) (*gm.Settings, error) {
	id, _ := identity.Parse(gm.SettingsID)
	now := s.now().UTC()
	st := gm.Settings{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}}
	var old gm.Settings
	exists := s.R.Get(ctx, "google_settings", id, &old) == nil
	if exists {
		st = old
		st.UpdatedAt = now
	}
	st.Enabled, st.ClientID, st.UpdatedBy = enabled, strings.TrimSpace(clientID), by.String()
	if clientSecret != "" {
		sealed, err := crypto.SealSecret(clientSecret, s.master(), "google/client")
		if err != nil {
			return nil, errs.Wrap(errs.CodeInternal, err, "seal Google client secret")
		}
		st.ClientSecret = sealed
	}
	if enabled && (st.ClientID == "" || st.ClientSecret == "") {
		return nil, errs.InvalidArgument("an enabled Google connection needs the OAuth client ID and secret")
	}
	var err error
	if exists {
		err = s.R.Update(ctx, "google_settings", id, &st)
	} else {
		err = s.R.CreateID(ctx, "google_settings", id, &st)
	}
	return &st, err
}

// Connected reports whether the person has a working connection.
func (s *Service) Connected(ctx context.Context, accountID string) bool {
	c, err := s.connection(ctx, accountID)
	return err == nil && c.Status == gm.StatusConnected
}

func (s *Service) connection(ctx context.Context, accountID string) (*gm.Connection, error) {
	id, err := identity.Parse(accountID)
	if err != nil {
		return nil, errs.InvalidArgument("invalid account")
	}
	var c gm.Connection
	if err := s.R.Get(ctx, "google_connections", id, &c); err != nil {
		if errs.CodeOf(err) == errs.CodeNotFound {
			return nil, errs.New(errs.CodeUnavailable, "Google is not connected: the person connects their account under Connections")
		}
		return nil, err
	}
	return &c, nil
}

// Disconnect forgets a person's connection (and revokes it at Google).
func (s *Service) Disconnect(ctx context.Context, accountID string) error {
	c, err := s.connection(ctx, accountID)
	if err != nil {
		return nil
	}
	if refresh, err := crypto.OpenSecret(c.RefreshToken, s.master(), "google/refresh/"+accountID); err == nil && !c.Fake {
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, "https://oauth2.googleapis.com/revoke?token="+url.QueryEscape(refresh), nil)
		if resp, err := s.HTTP.Do(req); err == nil {
			resp.Body.Close()
		}
	}
	s.mu.Lock()
	delete(s.tokens, accountID)
	s.mu.Unlock()
	return s.R.Delete(ctx, "google_connections", c.ID)
}

// RevokeConnection is Disconnect for an account deprovisioned.
func (s *Service) RevokeConnection(ctx context.Context, accountID string) error {
	return s.Disconnect(ctx, accountID)
}

// token is a current access token for the person, refreshed when needed.
func (s *Service) token(ctx context.Context, accountID string) (string, error) {
	s.mu.Lock()
	t, ok := s.tokens[accountID]
	s.mu.Unlock()
	if ok && s.now().Before(t.expires.Add(-time.Minute)) {
		return t.value, nil
	}
	c, err := s.connection(ctx, accountID)
	if err != nil {
		return "", err
	}
	refresh, err := crypto.OpenSecret(c.RefreshToken, s.master(), "google/refresh/"+accountID)
	if err != nil {
		return "", errs.Wrap(errs.CodeInternal, err, "open Google refresh token")
	}
	st, secret, err := s.settings(ctx)
	if err != nil {
		return "", err
	}
	form := url.Values{"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {st.ClientID}, "client_secret": {secret}}
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
		Error       string `json:"error"`
	}
	if err := s.postForm(ctx, s.endpoints().Token, form, &out); err != nil || out.AccessToken == "" {
		reason := out.Error
		if err != nil {
			reason = err.Error()
		}
		c.Status, c.LastError, c.UpdatedAt = gm.StatusBroken, reason, s.now().UTC()
		_ = s.R.Update(context.WithoutCancel(ctx), "google_connections", c.ID, c)
		return "", errs.New(errs.CodeUnavailable, "Google needs reconnecting under Connections ("+reason+")")
	}
	if out.ExpiresIn <= 0 {
		out.ExpiresIn = 3600
	}
	s.mu.Lock()
	s.tokens[accountID] = accessToken{value: out.AccessToken, expires: s.now().Add(time.Duration(out.ExpiresIn) * time.Second)}
	s.mu.Unlock()
	return out.AccessToken, nil
}

func (s *Service) postForm(ctx context.Context, endpoint string, form url.Values, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return s.do(req, out)
}

// api calls a Google API as the person.
func (s *Service) api(ctx context.Context, accountID, method, endpoint string, body any, out any) error {
	tok, err := s.token(ctx, accountID)
	if err != nil {
		return err
	}
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return s.do(req, out)
}

func (s *Service) do(req *http.Request, out any) error {
	resp, err := s.HTTP.Do(req)
	if err != nil {
		return errs.Wrap(errs.CodeUnavailable, err, "Google")
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if resp.StatusCode >= 300 {
		var e struct {
			Error any `json:"error"`
		}
		_ = json.Unmarshal(data, &e)
		msg := fmt.Sprint(e.Error)
		if m, ok := e.Error.(map[string]any); ok {
			msg = fmt.Sprint(m["message"])
		}
		if strings.TrimSpace(msg) == "" || msg == "<nil>" {
			msg = resp.Status
		}
		code := errs.CodeUnavailable
		switch resp.StatusCode {
		case http.StatusNotFound:
			code = errs.CodeNotFound
		case http.StatusBadRequest:
			code = errs.CodeInvalidArgument
		case http.StatusUnauthorized, http.StatusForbidden:
			code = errs.CodePermission
		}
		return errs.New(code, "Google: "+msg)
	}
	if out == nil || len(data) == 0 {
		return nil
	}
	return json.Unmarshal(data, out)
}

// isPerson reports a person's account (agents have no Google of their own).
func (s *Service) isPerson(ctx context.Context, id string) bool {
	parsed, err := identity.Parse(id)
	if err != nil {
		return false
	}
	var acc account.Account
	return s.R.Get(ctx, "accounts", parsed, &acc) == nil && acc.Kind == account.KindUser
}

func (s *Service) isAdmin(ctx context.Context, caller identity.ID) bool {
	var acc account.Account
	if s.R.Get(ctx, "accounts", caller, &acc) != nil || acc.Kind != account.KindUser {
		return false
	}
	return acc.Role == "admin" || (acc.Handle != "" && acc.Handle == s.K.Env()["admin_handle"])
}
