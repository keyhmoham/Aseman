package developer

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// KeyPrefix starts every secret, so a leaked one is easy to recognise and to scan for.
const KeyPrefix = "dk_live_"

// Permission levels.
const (
	LevelNone  = "none"
	LevelRead  = "read"
	LevelWrite = "write"
)

// Permissions are what a key may do, by part of the platform.
type Permissions struct {
	Models    string `json:"models"`
	Chat      string `json:"chat"`
	Computers string `json:"computers"`
	Files     string `json:"files"`
	Usage     string `json:"usage"`
	// Platform is the product surface (spaces, bots, tools, desk, messenger,
	// finance, themes, …) via POST /v1/platform/{namespace}/{action}. Read
	// lists the collection; write calls it. Node administration is never included.
	Platform string `json:"platform"`
}

func level(l string) int {
	switch l {
	case LevelWrite:
		return 2
	case LevelRead:
		return 1
	}
	return 0
}

// Allows reports whether a permission set grants at least a level.
func allows(have, need string) bool { return level(have) >= level(need) }

// Limits restrict a key beyond its permissions.
type Limits struct {
	// MonthlyCap is the most it may spend in a calendar month (ledger units). 0 = no cap.
	MonthlyCap int64 `json:"monthlyCap"`
	// RPM is requests per minute. 0 = the platform default.
	RPM       int64    `json:"rpm"`
	Models    []string `json:"models"`
	Providers []string `json:"providers"`
	ExpiresAt string   `json:"expiresAt,omitempty"`
}

// DefaultRPM is the requests-per-minute limit of a key that sets none.
const DefaultRPM = 600

// KeyView is a key as the console shows it: never the secret.
type KeyView struct {
	ID          string      `json:"id"`
	Name        string      `json:"name"`
	Prefix      string      `json:"prefix"`
	Last4       string      `json:"last4"`
	Status      string      `json:"status"`
	CreatedAt   string      `json:"createdAt"`
	CreatedBy   string      `json:"createdBy,omitempty"`
	LastUsedAt  string      `json:"lastUsedAt,omitempty"`
	Permissions Permissions `json:"permissions"`
	Limits      Limits      `json:"limits"`
	SpentMonth  int64       `json:"spentMonth"`
	Requests    int64       `json:"requests"`
	// Platform is the id of the platform the key is bound to ("": none).
	Platform string `json:"platform"`
}

// KeyInput is what a key is created or changed with.
type KeyInput struct {
	Name        string      `json:"name"`
	Permissions Permissions `json:"permissions"`
	Limits      Limits      `json:"limits"`
	// Platform binds the key to one of the organization's platforms (its id
	// or slug). Omitted on an update: the binding stays; "": unbound.
	Platform *string `json:"platform,omitempty"`
}

func hashSecret(secret string) string {
	sum := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(sum[:])
}

func monthKey(t time.Time) string { return t.UTC().Format("2006-01") }

func (s *Service) keyView(ctx context.Context, k models.Key) KeyView {
	var perms Permissions
	var limits Limits
	_ = json.Unmarshal([]byte(k.Permissions), &perms)
	_ = json.Unmarshal([]byte(k.Limits), &limits)
	if limits.Models == nil {
		limits.Models = []string{}
	}
	if limits.Providers == nil {
		limits.Providers = []string{}
	}
	spent := k.MonthSpent
	if k.MonthKey != monthKey(s.now()) {
		spent = 0
	}
	return KeyView{ID: k.ID.String(), Name: k.Name, Prefix: k.Prefix, Last4: k.Last4, Status: k.Status, CreatedAt: stamp(k.CreatedAt),
		CreatedBy: s.handleOf(ctx, k.CreatedBy), LastUsedAt: stamp(k.LastUsedAt), Permissions: perms, Limits: limits, SpentMonth: spent, Requests: k.Requests, Platform: k.PlatformID}
}

func cleanInput(in KeyInput) (KeyInput, error) {
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		in.Name = "Secret key"
	}
	if len([]rune(in.Name)) > 60 {
		return in, errs.InvalidArgument("A key's name can be up to 60 characters.")
	}
	check := func(l string, allowed ...string) string {
		if l == "" {
			return LevelNone
		}
		for _, a := range allowed {
			if l == a {
				return l
			}
		}
		return LevelNone
	}
	p := &in.Permissions
	p.Models = check(p.Models, LevelNone, LevelRead)
	p.Chat = check(p.Chat, LevelNone, LevelWrite)
	p.Computers = check(p.Computers, LevelNone, LevelRead, LevelWrite)
	p.Files = check(p.Files, LevelNone, LevelRead, LevelWrite)
	p.Usage = check(p.Usage, LevelNone, LevelRead)
	p.Platform = check(p.Platform, LevelNone, LevelRead, LevelWrite)
	if in.Limits.MonthlyCap < 0 || in.Limits.RPM < 0 {
		return in, errs.InvalidArgument("Limits cannot be negative.")
	}
	if in.Limits.ExpiresAt != "" {
		if _, err := time.Parse(time.RFC3339, in.Limits.ExpiresAt); err != nil {
			return in, errs.InvalidArgument("The expiry must be a date and time.")
		}
	}
	return in, nil
}

func (s *Service) loadKey(ctx context.Context, sc Scope, id string) (*models.Key, error) {
	kid, err := identity.Parse(id)
	if err != nil {
		return nil, errs.NotFound("key")
	}
	var k models.Key
	if err := s.R.Get(ctx, "dev_keys", kid, &k); err != nil || k.OrgID != sc.Org {
		return nil, errs.NotFound("key")
	}
	return &k, nil
}

// Keys lists an organization's keys, newest first.
func (s *Service) Keys(ctx context.Context, sc Scope) ([]KeyView, error) {
	var list []models.Key
	if err := s.R.List(ctx, "dev_keys", database.Filter{Equal: map[string]any{"org_id": sc.Org.String()}, OrderBy: "created_at"}, &list); err != nil {
		return nil, err
	}
	out := make([]KeyView, 0, len(list))
	for _, k := range list {
		out = append(out, s.keyView(ctx, k))
	}
	return out, nil
}

// CreateKey makes a key and returns its secret, the only time it is shown.
func (s *Service) CreateKey(ctx context.Context, caller identity.ID, sc Scope, in KeyInput) (KeyView, string, error) {
	if err := sc.Require("keys"); err != nil {
		return KeyView{}, "", err
	}
	in, err := cleanInput(in)
	if err != nil {
		return KeyView{}, "", err
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return KeyView{}, "", errs.Wrap(errs.CodeInternal, err, "generate key")
	}
	secret := KeyPrefix + base64.RawURLEncoding.EncodeToString(raw)
	id, err := s.newID()
	if err != nil {
		return KeyView{}, "", err
	}
	platform, err := s.keyPlatformOf(ctx, sc, in.Platform)
	if err != nil {
		return KeyView{}, "", err
	}
	perms, _ := json.Marshal(in.Permissions)
	limits, _ := json.Marshal(in.Limits)
	now := s.now()
	k := &models.Key{PlatformID: platform, Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, OrgID: sc.Org, Name: in.Name,
		Prefix: secret[:len(KeyPrefix)+4], Last4: secret[len(secret)-4:], Hash: hashSecret(secret),
		Permissions: string(perms), Limits: string(limits), Status: "active", CreatedBy: caller, MonthKey: monthKey(now)}
	if err := s.R.CreateID(ctx, "dev_keys", id, k); err != nil {
		return KeyView{}, "", err
	}
	return s.keyView(ctx, *k), secret, nil
}

// keyPlatformOf is the id of the organization's platform [ref] names ("" for
// none).
func (s *Service) keyPlatformOf(ctx context.Context, sc Scope, ref *string) (string, error) {
	if ref == nil || strings.TrimSpace(*ref) == "" {
		return "", nil
	}
	p, err := s.mustOrgPlatform(ctx, sc.Org, *ref)
	if err != nil {
		return "", err
	}
	return p.ID.String(), nil
}

// KeyPlatform is the platform what key [k] makes joins: the one it is bound
// to, else the organization's only platform. Nil: main Aseman (the
// organization has no platform). An unbound key of an organization with
// several platforms is refused: it must be bound to one.
func (s *Service) KeyPlatform(ctx context.Context, k models.Key) (*models.Platform, error) {
	if k.PlatformID != "" {
		p, err := s.PlatformByRef(ctx, k.PlatformID)
		if err != nil || p.OrgID != k.OrgID {
			return nil, errs.NotFound("the platform this key is bound to is gone: bind the key to another one")
		}
		return p, nil
	}
	p, err := s.OrgPlatform(ctx, k.OrgID, "")
	if err != nil {
		return nil, errs.InvalidArgument("this key is not bound to a platform and its organization has several: bind the key to one in the console")
	}
	return p, nil
}

// UpdateKey changes a key's name, permissions and limits.
func (s *Service) UpdateKey(ctx context.Context, sc Scope, id string, in KeyInput) (KeyView, error) {
	if err := sc.Require("keys"); err != nil {
		return KeyView{}, err
	}
	k, err := s.loadKey(ctx, sc, id)
	if err != nil {
		return KeyView{}, err
	}
	in, err = cleanInput(in)
	if err != nil {
		return KeyView{}, err
	}
	if in.Platform != nil {
		if k.PlatformID, err = s.keyPlatformOf(ctx, sc, in.Platform); err != nil {
			return KeyView{}, err
		}
	}
	perms, _ := json.Marshal(in.Permissions)
	limits, _ := json.Marshal(in.Limits)
	k.Name, k.Permissions, k.Limits, k.UpdatedAt = in.Name, string(perms), string(limits), s.now()
	if err := s.R.Update(ctx, "dev_keys", k.ID, k); err != nil {
		return KeyView{}, err
	}
	return s.keyView(ctx, *k), nil
}

// RevokeKey stops a key working at once. It stays in the list.
func (s *Service) RevokeKey(ctx context.Context, sc Scope, id string) error {
	if err := sc.Require("keys"); err != nil {
		return err
	}
	k, err := s.loadKey(ctx, sc, id)
	if err != nil {
		return err
	}
	k.Status, k.UpdatedAt = "revoked", s.now()
	return s.R.Update(ctx, "dev_keys", k.ID, k)
}

// DeleteKey removes a key from the list.
func (s *Service) DeleteKey(ctx context.Context, sc Scope, id string) error {
	if err := sc.Require("keys"); err != nil {
		return err
	}
	k, err := s.loadKey(ctx, sc, id)
	if err != nil {
		return err
	}
	return s.R.Delete(ctx, "dev_keys", k.ID)
}

// Principal is who an API request is: the key, and what it may do.
type Principal struct {
	Key         models.Key
	Org         identity.ID
	OrgName     string
	Permissions Permissions
	Limits      Limits
}

// AuthError is a refusal of an API request, with the status and code it is told with.
type AuthError struct {
	Status  int
	Type    string
	Code    string
	Message string
}

func (e *AuthError) Error() string { return e.Message }

// Authenticate resolves a bearer secret to a key that may be used now.
func (s *Service) Authenticate(ctx context.Context, secret string) (*Principal, error) {
	secret = strings.TrimSpace(secret)
	if !strings.HasPrefix(secret, KeyPrefix) {
		return nil, &AuthError{401, "authentication_error", "invalid_api_key", "Missing or invalid API key. Send it as: Authorization: Bearer " + KeyPrefix + "…"}
	}
	var list []models.Key
	if err := s.R.List(ctx, "dev_keys", database.Filter{Equal: map[string]any{"hash": hashSecret(secret)}, Limit: 1}, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, &AuthError{401, "authentication_error", "invalid_api_key", "That API key is not valid."}
	}
	k := list[0]
	if k.Status != "active" {
		return nil, &AuthError{401, "authentication_error", "key_revoked", "That API key has been revoked."}
	}
	p := &Principal{Key: k, Org: k.OrgID}
	_ = json.Unmarshal([]byte(k.Permissions), &p.Permissions)
	_ = json.Unmarshal([]byte(k.Limits), &p.Limits)
	if p.Limits.ExpiresAt != "" {
		if t, err := time.Parse(time.RFC3339, p.Limits.ExpiresAt); err == nil && !s.now().Before(t) {
			return nil, &AuthError{401, "authentication_error", "key_expired", "That API key has expired."}
		}
	}
	name, _, err := s.ScopeOf(ctx, k.OrgID)
	if err != nil {
		return nil, &AuthError{401, "authentication_error", "invalid_api_key", "That API key's organization no longer exists."}
	}
	p.OrgName = name
	return p, nil
}

// Need refuses a request outside the key's permissions.
func (p *Principal) Need(resource, lvl string) error {
	have := map[string]string{
		"models": p.Permissions.Models, "chat": p.Permissions.Chat,
		"computers": p.Permissions.Computers, "files": p.Permissions.Files,
		"usage": p.Permissions.Usage, "platform": p.Permissions.Platform,
	}[resource]
	if allows(have, lvl) {
		return nil
	}
	return &AuthError{403, "permission_error", "permission_denied", "This key does not have " + lvl + " access to " + resource + ". Change it under API keys in the console."}
}

type window struct {
	start time.Time
	count int64
}

// Allow counts a request against the key's per-minute limit. It returns how
// many requests are left in the minute, or the seconds to wait.
func (s *Service) Allow(p *Principal) (limit, remaining int64, retry int, ok bool) {
	limit = p.Limits.RPM
	if limit <= 0 {
		limit = DefaultRPM
	}
	now := s.now()
	s.limitMu.Lock()
	defer s.limitMu.Unlock()
	w := s.limiters[p.Key.ID.String()]
	if w == nil || now.Sub(w.start) >= time.Minute {
		w = &window{start: now}
		s.limiters[p.Key.ID.String()] = w
	}
	if w.count >= limit {
		return limit, 0, int(w.start.Add(time.Minute).Sub(now).Seconds()) + 1, false
	}
	w.count++
	return limit, limit - w.count, 0, true
}

// SpendCheck refuses a request when the key's monthly cap, or the
// organization's, is already used up.
func (s *Service) SpendCheck(ctx context.Context, p *Principal) error {
	month := monthKey(s.now())
	if p.Limits.MonthlyCap > 0 {
		spent := p.Key.MonthSpent
		if p.Key.MonthKey != month {
			spent = 0
		}
		if spent >= p.Limits.MonthlyCap {
			return &AuthError{402, "billing_error", "key_cap_reached", "This key has spent its monthly cap. Raise it under API keys in the console, or wait for the next month."}
		}
	}
	st, err := s.settings(ctx, p.Org)
	if err != nil {
		return err
	}
	if st.MonthlyCap > 0 && st.MonthKey == month && st.MonthSpent >= st.MonthlyCap {
		return &AuthError{402, "billing_error", "org_cap_reached", "This organization has reached its monthly spend limit. Raise it under Billing in the console."}
	}
	return nil
}

// recordUse adds a request, and what it cost, to the key and the organization.
func (s *Service) recordUse(ctx context.Context, p *Principal, cost int64) {
	now := s.now()
	month := monthKey(now)
	var k models.Key
	if err := s.R.Get(ctx, "dev_keys", p.Key.ID, &k); err != nil {
		return
	}
	if k.MonthKey != month {
		k.MonthKey, k.MonthSpent = month, 0
	}
	k.MonthSpent += cost
	k.Requests++
	k.LastUsedAt = now
	if err := s.R.Update(ctx, "dev_keys", k.ID, &k); err != nil {
		s.L.Warn("record key use", "error", err)
	}
	if cost > 0 {
		if st, err := s.settings(ctx, p.Org); err == nil {
			if st.MonthKey != month {
				st.MonthKey, st.MonthSpent = month, 0
			}
			st.MonthSpent += cost
			st.UpdatedAt = now
			if err := s.R.DB.Update(ctx, "dev_settings", p.Org.String(), st); err != nil {
				s.L.Warn("record org spend", "error", err)
			}
		}
	}
}

// settings loads an organization's limits, creating them empty on first use.
func (s *Service) settings(ctx context.Context, org identity.ID) (*models.Settings, error) {
	var st models.Settings
	err := s.R.DB.Get(ctx, "dev_settings", org.String(), &st)
	if err == nil {
		return &st, nil
	}
	if errs.CodeOf(err) != errs.CodeNotFound {
		return nil, err
	}
	now := s.now()
	st = models.Settings{Entity: entity.Entity{ID: org, CreatedAt: now, UpdatedAt: now}, MonthKey: monthKey(now)}
	if err := s.R.DB.Create(ctx, "dev_settings", org.String(), &st); err != nil {
		return nil, err
	}
	return &st, nil
}
