package talent

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/models/metadata"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/actions/talent/models"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
)

// Talent requests: a person describes work they need done (a title, a
// category, a budget…). Partners read the open ones through the API; the app
// shows a person their own. Nothing here moves money.

// RequestCategories are what a request can be about, in display order.
var RequestCategories = []string{"Development", "Design", "Marketing", "Community", "Research", "Other"}

// RequestBudgetTypes say how the budget is counted.
var RequestBudgetTypes = []string{"fixed", "hourly", "monthly"}

// RequestTimelines are how long the work is expected to take (optional on a request).
var RequestTimelines = []string{"flexible", "lt_1_week", "1_4_weeks", "1_3_months", "ongoing"}

// Limits on a request.
const (
	MinTitle       = 5
	MaxTitle       = 120
	MinDescription = 50
	MaxDescription = 5000
	MinCompany     = 2
	MaxCompany     = 80
	MaxSkills      = 10
	MaxSkill       = 40
	MaxBudgetUSD   = 1_000_000
	// MaxOpenPerPerson bounds how many open requests one person has at once.
	MaxOpenPerPerson = 10
)

// RequestInput is what a person posts.
type RequestInput struct {
	Title       string `json:"title"`
	Category    string `json:"category"`
	Description string `json:"description"`
	BudgetType  string `json:"budget_type"`
	// BudgetAmount is in US dollars.
	BudgetAmount float64  `json:"budget_amount"`
	Company      string   `json:"company"`
	Timeline     string   `json:"timeline"`
	Skills       []string `json:"skills"`
	// Space is the project it is posted from (optional).
	Space string `json:"space"`
	// RequestID makes a retry post once.
	RequestID string `json:"request_id"`
}

func pick(list []string, v string) (string, bool) {
	for _, item := range list {
		if strings.EqualFold(item, strings.TrimSpace(v)) {
			return item, true
		}
	}
	return "", false
}

// tidy trims text, turns line endings into \n and drops control characters
// other than newlines and tabs.
func tidy(text string) string {
	text = strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n")
	text = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) && r != '\n' && r != '\t' {
			return -1
		}
		return r
	}, text)
	return strings.TrimSpace(text)
}

func between(text string, min, max int, what string) error {
	n := utf8.RuneCountInString(text)
	if n < min {
		return errs.InvalidArgument(what + " must be at least " + strconv.Itoa(min) + " characters.")
	}
	if n > max {
		return errs.InvalidArgument(what + " must be at most " + strconv.Itoa(max) + " characters.")
	}
	return nil
}

// cleanRequest checks a request and returns it as it is stored.
func cleanRequest(in RequestInput) (models.Request, error) {
	var r models.Request
	r.Title = strings.Join(strings.Fields(tidy(in.Title)), " ")
	if err := between(r.Title, MinTitle, MaxTitle, "The title"); err != nil {
		return r, err
	}
	category, ok := pick(RequestCategories, in.Category)
	if !ok {
		return r, errs.InvalidArgument("Choose a category: " + strings.Join(RequestCategories, ", ") + ".")
	}
	r.Category = category
	r.Description = tidy(in.Description)
	if err := between(r.Description, MinDescription, MaxDescription, "The description"); err != nil {
		return r, err
	}
	budgetType, ok := pick(RequestBudgetTypes, in.BudgetType)
	if !ok {
		return r, errs.InvalidArgument("Choose how the budget is counted: fixed, hourly or monthly.")
	}
	r.BudgetType = budgetType
	if math.IsNaN(in.BudgetAmount) || math.IsInf(in.BudgetAmount, 0) || in.BudgetAmount < 1 {
		return r, errs.InvalidArgument("The budget must be at least $1.")
	}
	if in.BudgetAmount > MaxBudgetUSD {
		return r, errs.InvalidArgument("The budget must be at most $" + strconv.Itoa(MaxBudgetUSD) + ".")
	}
	r.BudgetCents = int64(math.Round(in.BudgetAmount * 100))
	r.Company = strings.Join(strings.Fields(tidy(in.Company)), " ")
	if err := between(r.Company, MinCompany, MaxCompany, "The company or project name"); err != nil {
		return r, err
	}
	if t := strings.TrimSpace(in.Timeline); t != "" {
		timeline, ok := pick(RequestTimelines, t)
		if !ok {
			return r, errs.InvalidArgument("Choose a timeline: flexible, under a week, 1–4 weeks, 1–3 months or ongoing.")
		}
		r.Timeline = timeline
	}
	skills := []string{}
	seen := map[string]bool{}
	for _, s := range in.Skills {
		s = strings.Join(strings.Fields(tidy(s)), " ")
		if s == "" || seen[strings.ToLower(s)] {
			continue
		}
		if utf8.RuneCountInString(s) > MaxSkill {
			return r, errs.InvalidArgument("A skill must be at most " + strconv.Itoa(MaxSkill) + " characters.")
		}
		seen[strings.ToLower(s)] = true
		skills = append(skills, s)
	}
	if len(skills) > MaxSkills {
		return r, errs.InvalidArgument("Add at most " + strconv.Itoa(MaxSkills) + " skills.")
	}
	b, _ := json.Marshal(skills)
	r.Skills = string(b)
	r.Status = models.RequestOpen
	return r, nil
}

func skillsOf(r models.Request) []string {
	out := []string{}
	_ = json.Unmarshal([]byte(r.Skills), &out)
	return out
}

func stamp(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

// requestView is a request as its poster (and the admin) sees it.
func requestView(r models.Request) map[string]any {
	return map[string]any{
		"id": r.ID.String(), "title": r.Title, "category": r.Category, "description": r.Description,
		"budget_type": r.BudgetType, "budget_amount": float64(r.BudgetCents) / 100, "company": r.Company,
		"timeline": r.Timeline, "skills": skillsOf(r), "status": r.Status, "space_id": r.SpaceID.String(),
		"created_at": stamp(r.CreatedAt), "updated_at": stamp(r.UpdatedAt),
	}
}

// poster is who to contact about a request: the name and email of the person who
// posted it. The form tells them it is shared with partners.
func (s *Service) poster(ctx context.Context, id identity.ID) map[string]any {
	var acc account.Account
	if s.R.Get(ctx, "accounts", id, &acc) != nil {
		return nil
	}
	name := acc.Handle
	var rec metadata.Record
	if s.R.GetString(ctx, "metadatas", id.String(), &rec) == nil {
		if profile, ok := rec.Tree["profile"].(map[string]any); ok {
			if n := helper.PersonName(profile, acc.Handle); n != "" {
				name = n
			}
		}
	}
	return map[string]any{"name": name, "email": acc.Email}
}

// partnerView is a request as a partner sees it: what it says, and who posted it
// (name and email, to get in touch). Never the project it came from.
func (s *Service) partnerView(ctx context.Context, r models.Request) map[string]any {
	return map[string]any{
		"poster": s.poster(ctx, r.OwnerID),
		"id":     r.ID.String(), "title": r.Title, "category": r.Category, "description": r.Description,
		"budget":  map[string]any{"type": r.BudgetType, "amount": float64(r.BudgetCents) / 100, "currency": "USD"},
		"company": r.Company, "timeline": nilIfEmpty(r.Timeline), "skills": skillsOf(r), "status": "open",
		"created_at": stamp(r.CreatedAt), "updated_at": stamp(r.UpdatedAt),
	}
}

func nilIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// ── the app's actions ───────────────────────────────────────────────────────

func (s *Service) requestCreate(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in RequestInput
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	r, err := cleanRequest(in)
	if err != nil {
		return nil, err
	}
	caller := req.Caller.ID
	if strings.TrimSpace(in.Space) != "" {
		sp, err := identity.Parse(in.Space)
		if err != nil {
			return nil, errs.InvalidArgument("invalid project")
		}
		if err := helper.CheckSpaceAccess(ctx, s.R, caller, sp, identity.ID{}, false); err != nil {
			return nil, err
		}
		r.SpaceID = sp
	}
	id, err := s.requestID(caller, in.RequestID)
	if err != nil {
		return nil, err
	}
	var existing models.Request
	if s.R.Get(ctx, "talent_requests", id, &existing) == nil {
		if existing.OwnerID != caller {
			return nil, errs.Conflict("request id already used")
		}
		return helper.JSON(map[string]any{"ok": true, "request": requestView(existing)})
	}
	var open []models.Request
	if err := s.R.List(ctx, "talent_requests", database.Filter{Equal: map[string]any{"owner_id": caller.String(), "status": models.RequestOpen}, Limit: MaxOpenPerPerson}, &open); err != nil {
		return nil, err
	}
	if len(open) >= MaxOpenPerPerson {
		return nil, errs.Conflict("You have " + strconv.Itoa(MaxOpenPerPerson) + " open requests. Close one to post another.")
	}
	now := time.Now().UTC()
	r.Entity = entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}
	r.OwnerID = caller
	if err := s.R.CreateID(ctx, "talent_requests", id, &r); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "request": requestView(r)})
}

// requestID is the id of a request: new each time, or the same for a retry that carries its request_id.
func (s *Service) requestID(caller identity.ID, requestID string) (identity.ID, error) {
	if strings.TrimSpace(requestID) == "" {
		return identity.New(s.K.NodeID())
	}
	return identity.Parse(s.K.NodeID().String() + repo.ExecutionKey("talent-request/" + caller.String() + "/" + strings.TrimSpace(requestID))[16:])
}

func (s *Service) requestList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var rows []models.Request
	if err := s.R.List(ctx, "talent_requests", database.Filter{Equal: map[string]any{"owner_id": req.Caller.ID.String()}, OrderBy: "created_at", Limit: 200}, &rows); err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		if r.Status != models.RequestDeleted {
			out = append(out, requestView(r))
		}
	}
	return helper.JSON(map[string]any{"requests": out})
}

// ownRequest loads a request that belongs to the caller.
func (s *Service) ownRequest(ctx context.Context, req *api.ActionRequest, ref string) (*models.Request, error) {
	id, err := identity.Parse(strings.TrimSpace(ref))
	if err != nil {
		return nil, errs.NotFound("request")
	}
	var r models.Request
	if err := s.R.Get(ctx, "talent_requests", id, &r); err != nil || r.OwnerID != req.Caller.ID || r.Status == models.RequestDeleted {
		return nil, errs.NotFound("request")
	}
	return &r, nil
}

func (s *Service) requestStatus(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		ID     string `json:"id"`
		Status string `json:"status"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if in.Status != models.RequestOpen && in.Status != models.RequestClosed {
		return nil, errs.InvalidArgument("status must be open or closed")
	}
	r, err := s.ownRequest(ctx, req, in.ID)
	if err != nil {
		return nil, err
	}
	if r.Status == models.RequestHidden {
		return nil, errs.Permission("This request was removed and cannot be reopened.")
	}
	if r.Status != in.Status {
		if in.Status == models.RequestOpen {
			var open []models.Request
			if err := s.R.List(ctx, "talent_requests", database.Filter{Equal: map[string]any{"owner_id": req.Caller.ID.String(), "status": models.RequestOpen}, Limit: MaxOpenPerPerson}, &open); err != nil {
				return nil, err
			}
			if len(open) >= MaxOpenPerPerson {
				return nil, errs.Conflict("You have " + strconv.Itoa(MaxOpenPerPerson) + " open requests. Close one first.")
			}
		}
		r.Status, r.UpdatedAt = in.Status, time.Now().UTC()
		if err := s.R.Update(ctx, "talent_requests", r.ID, r); err != nil {
			return nil, err
		}
	}
	return helper.JSON(map[string]any{"ok": true, "request": requestView(*r)})
}

func (s *Service) requestDelete(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		ID string `json:"id"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	r, err := s.ownRequest(ctx, req, in.ID)
	if err != nil {
		return nil, err
	}
	if r.Status == models.RequestHidden {
		return nil, errs.Permission("This request was removed by the node's admin.")
	}
	// Kept, as deleted: a partner syncing changes must hear that it is gone.
	r.Status, r.UpdatedAt = models.RequestDeleted, time.Now().UTC()
	if err := s.R.Update(ctx, "talent_requests", r.ID, r); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

// ── the admin's actions ─────────────────────────────────────────────────────

func (s *Service) requireAdmin(ctx context.Context, req *api.ActionRequest) error {
	return helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"])
}

func (s *Service) handleOf(ctx context.Context, id identity.ID) string {
	var acc account.Account
	if err := s.R.Get(ctx, "accounts", id, &acc); err != nil {
		return ""
	}
	return acc.Handle
}

func (s *Service) adminRequests(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := s.requireAdmin(ctx, req); err != nil {
		return nil, err
	}
	var in struct {
		Status string `json:"status"`
		Limit  int    `json:"limit"`
	}
	_ = json.Unmarshal(req.Body, &in)
	if in.Limit <= 0 || in.Limit > 500 {
		in.Limit = 200
	}
	f := database.Filter{OrderBy: "created_at", Limit: in.Limit}
	if in.Status == models.RequestOpen || in.Status == models.RequestClosed || in.Status == models.RequestHidden || in.Status == models.RequestDeleted {
		f.Equal = map[string]any{"status": in.Status}
	}
	var rows []models.Request
	if err := s.R.List(ctx, "talent_requests", f, &rows); err != nil {
		return nil, err
	}
	handles := map[string]string{}
	out := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		v := requestView(r)
		h, ok := handles[r.OwnerID.String()]
		if !ok {
			h = s.handleOf(ctx, r.OwnerID)
			handles[r.OwnerID.String()] = h
		}
		v["owner_id"], v["owner_handle"] = r.OwnerID.String(), h
		out = append(out, v)
	}
	return helper.JSON(map[string]any{"requests": out})
}

func (s *Service) adminRequestStatus(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := s.requireAdmin(ctx, req); err != nil {
		return nil, err
	}
	var in struct {
		ID     string `json:"id"`
		Status string `json:"status"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if in.Status != models.RequestOpen && in.Status != models.RequestClosed && in.Status != models.RequestHidden {
		return nil, errs.InvalidArgument("status must be open, closed or hidden")
	}
	id, err := identity.Parse(strings.TrimSpace(in.ID))
	if err != nil {
		return nil, errs.NotFound("request")
	}
	var r models.Request
	if err := s.R.Get(ctx, "talent_requests", id, &r); err != nil || r.Status == models.RequestDeleted {
		return nil, errs.NotFound("request")
	}
	if r.Status != in.Status {
		r.Status, r.UpdatedAt = in.Status, time.Now().UTC()
		if err := s.R.Update(ctx, "talent_requests", r.ID, &r); err != nil {
			return nil, err
		}
	}
	return helper.JSON(map[string]any{"ok": true, "request": requestView(r)})
}

// ── partner keys ────────────────────────────────────────────────────────────

const partnerKeyPrefix = "pk_live_"

func hashSecret(secret string) string {
	sum := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(sum[:])
}

func keyView(k models.PartnerKey) map[string]any {
	return map[string]any{"id": k.ID.String(), "name": k.Name, "prefix": k.Prefix, "last4": k.Last4, "status": k.Status,
		"created_at": stamp(k.CreatedAt), "last_used_at": stamp(k.LastUsedAt), "requests": k.Requests}
}

func (s *Service) partnerKeys(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := s.requireAdmin(ctx, req); err != nil {
		return nil, err
	}
	var rows []models.PartnerKey
	if err := s.R.List(ctx, "talent_partner_keys", database.Filter{OrderBy: "created_at", Limit: 200}, &rows); err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(rows))
	for _, k := range rows {
		out = append(out, keyView(k))
	}
	return helper.JSON(map[string]any{"keys": out})
}

func (s *Service) partnerKeyCreate(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := s.requireAdmin(ctx, req); err != nil {
		return nil, err
	}
	var in struct {
		Name string `json:"name"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	name := strings.TrimSpace(in.Name)
	if utf8.RuneCountInString(name) < 2 || utf8.RuneCountInString(name) > 60 {
		return nil, errs.InvalidArgument("Name the partner, 2 to 60 characters.")
	}
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		return nil, err
	}
	secret := partnerKeyPrefix + hex.EncodeToString(raw)
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	k := models.PartnerKey{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, Name: name, Prefix: secret[:len(partnerKeyPrefix)+4],
		Last4: secret[len(secret)-4:], Hash: hashSecret(secret), Status: "active"}
	if err := s.R.CreateID(ctx, "talent_partner_keys", id, &k); err != nil {
		return nil, err
	}
	// The secret is shown once: only its hash is kept.
	return helper.JSON(map[string]any{"key": keyView(k), "secret": secret})
}

func (s *Service) partnerKeyRevoke(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := s.requireAdmin(ctx, req); err != nil {
		return nil, err
	}
	var in struct {
		ID string `json:"id"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(strings.TrimSpace(in.ID))
	if err != nil {
		return nil, errs.NotFound("key")
	}
	var k models.PartnerKey
	if err := s.R.Get(ctx, "talent_partner_keys", id, &k); err != nil {
		return nil, errs.NotFound("key")
	}
	k.Status, k.UpdatedAt = "revoked", time.Now().UTC()
	if err := s.R.Update(ctx, "talent_partner_keys", id, &k); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

// ── the partner API ─────────────────────────────────────────────────────────

// partnerPrefix is where the partner routes live in the router: the developer
// host's /v1/... is mapped onto /dev/v1/..., so on that host this is
// /v1/partner/talent-requests.
const partnerPrefix = "/dev/v1/partner/talent-requests"

// partnerRate is how many requests one key may make a minute.
const partnerRate = 120

type limiter struct {
	mu     sync.Mutex
	window map[string][2]int64 // key id → minute, count
}

func (l *limiter) allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.window == nil {
		l.window = map[string][2]int64{}
	}
	minute := now.Unix() / 60
	w := l.window[key]
	if w[0] != minute {
		w = [2]int64{minute, 0}
	}
	w[1]++
	l.window[key] = w
	return w[1] <= partnerRate
}

func partnerError(status int, typ, code, message string) *network.Response {
	body, _ := json.Marshal(map[string]any{"error": map[string]any{"type": typ, "code": code, "message": message}})
	return &network.Response{Status: status, Header: map[string]string{"Content-Type": "application/json"}, Body: body}
}

func partnerJSON(status int, v any) *network.Response {
	body, _ := json.Marshal(v)
	return &network.Response{Status: status, Header: map[string]string{"Content-Type": "application/json", "Cache-Control": "private, max-age=15"}, Body: body}
}

func bearer(req *network.Request) string {
	for k, v := range req.Header {
		if strings.EqualFold(k, "Authorization") && strings.HasPrefix(v, "Bearer ") {
			return strings.TrimSpace(strings.TrimPrefix(v, "Bearer "))
		}
	}
	return ""
}

// partnerAuth finds the active key a request carries, or answers why not.
func (s *Service) partnerAuth(ctx context.Context, req *network.Request) (*models.PartnerKey, *network.Response) {
	secret := bearer(req)
	if !strings.HasPrefix(secret, partnerKeyPrefix) {
		return nil, partnerError(http.StatusUnauthorized, "authentication_error", "missing_key", "Send your partner key as a bearer token: Authorization: Bearer pk_live_…")
	}
	var rows []models.PartnerKey
	if err := s.R.List(ctx, "talent_partner_keys", database.Filter{Equal: map[string]any{"hash": hashSecret(secret)}, Limit: 1}, &rows); err != nil {
		return nil, partnerError(http.StatusInternalServerError, "api_error", "internal_error", "Something went wrong on our side.")
	}
	if len(rows) == 0 || rows[0].Status != "active" {
		return nil, partnerError(http.StatusUnauthorized, "authentication_error", "invalid_key", "That key is not valid. It may have been revoked.")
	}
	if !s.limit.allow(rows[0].ID.String(), time.Now()) {
		r := partnerError(http.StatusTooManyRequests, "rate_limit_error", "rate_limited", "Too many requests: at most "+strconv.Itoa(partnerRate)+" a minute.")
		r.Header["Retry-After"] = "30"
		return nil, r
	}
	return &rows[0], nil
}

// touch records a key's use, at most once a minute so a busy partner is not a write storm.
func (s *Service) touch(ctx context.Context, k *models.PartnerKey) {
	now := time.Now().UTC()
	k.Requests++
	if now.Sub(k.LastUsedAt) < time.Minute {
		return
	}
	k.LastUsedAt, k.UpdatedAt = now, now
	_ = s.R.Update(ctx, "talent_partner_keys", k.ID, k)
}

func (s *Service) apiList(ctx context.Context, req *network.Request) (*network.Response, error) {
	key, bad := s.partnerAuth(ctx, req)
	if bad != nil {
		return bad, nil
	}
	s.touch(ctx, key)
	limit, _ := strconv.Atoi(req.Query.Get("limit"))
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	category := ""
	if c := strings.TrimSpace(req.Query.Get("category")); c != "" {
		v, ok := pick(RequestCategories, c)
		if !ok {
			return partnerError(http.StatusBadRequest, "invalid_request_error", "invalid_category", "category must be one of: "+strings.Join(RequestCategories, ", ")+"."), nil
		}
		category = v
	}
	// Changes since a moment, oldest first: what was posted, and what closed or was taken down.
	if since := strings.TrimSpace(req.Query.Get("updated_since")); since != "" {
		t, err := time.Parse(time.RFC3339Nano, since)
		if err != nil {
			return partnerError(http.StatusBadRequest, "invalid_request_error", "invalid_updated_since", "updated_since must be an RFC 3339 time, such as 2026-10-16T09:00:00Z."), nil
		}
		f := database.Filter{GreaterThan: map[string]any{"updated_at": t}, OrderBy: "updated_at", Asc: true, Limit: limit + 1}
		if category != "" {
			f.Equal = map[string]any{"category": category}
		}
		var rows []models.Request
		if err := s.R.List(ctx, "talent_requests", f, &rows); err != nil {
			return partnerError(http.StatusInternalServerError, "api_error", "internal_error", "Something went wrong on our side."), nil
		}
		more := len(rows) > limit
		if more {
			rows = rows[:limit]
		}
		data := make([]map[string]any, 0, len(rows))
		next := since
		for _, r := range rows {
			if r.Status == models.RequestOpen {
				data = append(data, s.partnerView(ctx, r))
			} else {
				// Closed, or taken down: only that it is gone.
				data = append(data, map[string]any{"id": r.ID.String(), "status": "closed", "updated_at": stamp(r.UpdatedAt)})
			}
			next = r.UpdatedAt.UTC().Format(time.RFC3339Nano)
		}
		return partnerJSON(http.StatusOK, map[string]any{"object": "list", "data": data, "has_more": more, "next_updated_since": next}), nil
	}
	// The open requests, newest first.
	f := database.Filter{Equal: map[string]any{"status": models.RequestOpen}, OrderBy: "created_at", Limit: limit + 1}
	if category != "" {
		f.Equal["category"] = category
	}
	if cursor := strings.TrimSpace(req.Query.Get("cursor")); cursor != "" {
		raw, err := base64.RawURLEncoding.DecodeString(cursor)
		n, perr := strconv.ParseInt(string(raw), 10, 64)
		if err != nil || perr != nil {
			return partnerError(http.StatusBadRequest, "invalid_request_error", "invalid_cursor", "cursor is not one this API gave you."), nil
		}
		f.LessThan = map[string]any{"created_at": time.Unix(0, n).UTC()}
	}
	var rows []models.Request
	if err := s.R.List(ctx, "talent_requests", f, &rows); err != nil {
		return partnerError(http.StatusInternalServerError, "api_error", "internal_error", "Something went wrong on our side."), nil
	}
	more := len(rows) > limit
	if more {
		rows = rows[:limit]
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].CreatedAt.After(rows[j].CreatedAt) })
	data := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		data = append(data, s.partnerView(ctx, r))
	}
	var next any
	if more && len(rows) > 0 {
		next = base64.RawURLEncoding.EncodeToString([]byte(strconv.FormatInt(rows[len(rows)-1].CreatedAt.UnixNano(), 10)))
	}
	return partnerJSON(http.StatusOK, map[string]any{"object": "list", "data": data, "has_more": more, "next_cursor": next}), nil
}

func (s *Service) apiGet(ctx context.Context, req *network.Request) (*network.Response, error) {
	key, bad := s.partnerAuth(ctx, req)
	if bad != nil {
		return bad, nil
	}
	s.touch(ctx, key)
	params := map[string]string{}
	if raw := req.Header["x-route-params"]; raw != "" {
		_ = json.Unmarshal([]byte(raw), &params)
	}
	id, err := identity.Parse(params["id"])
	var r models.Request
	if err != nil || s.R.Get(ctx, "talent_requests", id, &r) != nil || r.Status != models.RequestOpen {
		return partnerError(http.StatusNotFound, "not_found_error", "not_found", "No open request with that id."), nil
	}
	return partnerJSON(http.StatusOK, s.partnerView(ctx, r)), nil
}

// Register binds the partner routes to a network adapter.
func (s *Service) Register(net network.Network) error {
	if err := net.Handle(network.MethodGet, partnerPrefix, s.apiList); err != nil {
		return err
	}
	return net.Handle(network.MethodGet, partnerPrefix+"/{id}", s.apiGet)
}

// Unregister removes them.
func (s *Service) Unregister(net network.Network) error {
	_ = net.Unhandle(network.MethodGet, partnerPrefix)
	_ = net.Unhandle(network.MethodGet, partnerPrefix+"/{id}")
	return nil
}

// requestActions are the namespace's actions on requests and partner keys.
func (s *Service) requestActions() []api.Action {
	act := func(name, summary string, h func(context.Context, *api.ActionRequest) (*api.ActionResponse, error)) api.Action {
		return helper.Action{Namespace: "talent", Name: name, Summary: summary, Handler: h}
	}
	return []api.Action{
		act("request_create", "Post a request for talent", s.requestCreate),
		act("request_list", "The requests you posted", s.requestList),
		act("request_status", "Close or reopen a request of yours", s.requestStatus),
		act("request_delete", "Delete a request of yours", s.requestDelete),
		act("admin_requests", "Admin: every request", s.adminRequests),
		act("admin_request_status", "Admin: open, close or take down a request", s.adminRequestStatus),
		act("partner_keys", "Admin: the partner API keys", s.partnerKeys),
		act("partner_key_create", "Admin: make a partner API key (the secret is shown once)", s.partnerKeyCreate),
		act("partner_key_revoke", "Admin: revoke a partner API key", s.partnerKeyRevoke),
	}
}
