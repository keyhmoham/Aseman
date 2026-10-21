package talent

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/actions/talent/models"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	nethttp "github.com/aseman/aseman/plugins/adapters/network/http"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

const longText = "We need a careful engineer to build the first version of our booking flow, from the data model to the checkout."

func goodInput() RequestInput {
	return RequestInput{Title: "  Build   our booking flow ", Category: "development", Description: longText, BudgetType: "Fixed", BudgetAmount: 1500.505,
		Company: "Acme Labs", Timeline: "1_4_weeks", Skills: []string{"Go", " react ", "GO", ""}}
}

func TestARequestIsCheckedAndTidied(t *testing.T) {
	r, err := cleanRequest(goodInput())
	if err != nil {
		t.Fatal(err)
	}
	if r.Title != "Build our booking flow" || r.Category != "Development" || r.BudgetType != "fixed" || r.BudgetCents != 150051 || r.Timeline != "1_4_weeks" || r.Status != models.RequestOpen {
		t.Fatalf("tidied: %+v", r)
	}
	if got := skillsOf(r); len(got) != 2 || got[0] != "Go" || got[1] != "react" {
		t.Fatalf("skills are trimmed and not repeated: %v", got)
	}
	bad := map[string]func(*RequestInput){
		"title short":       func(i *RequestInput) { i.Title = "Hi" },
		"title long":        func(i *RequestInput) { i.Title = strings.Repeat("a", MaxTitle+1) },
		"category":          func(i *RequestInput) { i.Category = "Plumbing" },
		"description short": func(i *RequestInput) { i.Description = strings.Repeat("x", MinDescription-1) },
		"description long":  func(i *RequestInput) { i.Description = strings.Repeat("x", MaxDescription+1) },
		"budget type":       func(i *RequestInput) { i.BudgetType = "weekly" },
		"budget zero":       func(i *RequestInput) { i.BudgetAmount = 0 },
		"budget huge":       func(i *RequestInput) { i.BudgetAmount = MaxBudgetUSD + 1 },
		"company":           func(i *RequestInput) { i.Company = " " },
		"timeline":          func(i *RequestInput) { i.Timeline = "soon" },
		"too many skills": func(i *RequestInput) {
			i.Skills = nil
			for n := 0; n < MaxSkills+1; n++ {
				i.Skills = append(i.Skills, "skill"+strings.Repeat("x", n))
			}
		},
		"a skill too long": func(i *RequestInput) { i.Skills = []string{strings.Repeat("s", MaxSkill+1)} },
	}
	for name, mutate := range bad {
		in := goodInput()
		mutate(&in)
		if _, err := cleanRequest(in); errs.CodeOf(err) != errs.CodeInvalidArgument {
			t.Fatalf("%s should be refused: %v", name, err)
		}
	}
	edge := goodInput()
	edge.Description, edge.Timeline, edge.Skills = strings.Repeat("é", MinDescription), "", nil
	if r, err := cleanRequest(edge); err != nil || r.Timeline != "" || r.Skills != "[]" {
		t.Fatalf("50 characters, no timeline, no skills: %v %+v", err, r)
	}
}

type fixture struct {
	s      *Service
	ctx    context.Context
	ada    identity.ID
	admin  identity.ID
	secret string
}

func harness(t *testing.T) *fixture {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := context.Background()
	for _, m := range dbmodel.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	for _, m := range models.Models() {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"admin_handle": "root"}})
	s := &Service{K: k, R: &repo.Repo{DB: db}}
	person := func(handle string) identity.ID {
		id, _ := identity.New(1)
		if err := s.R.CreateID(ctx, "accounts", id, account.New(id, account.KindUser, handle, handle+"@x.test")); err != nil {
			t.Fatal(err)
		}
		return id
	}
	return &fixture{s: s, ctx: ctx, ada: person("ada"), admin: person("root")}
}

func (f *fixture) call(t *testing.T, h func(context.Context, *api.ActionRequest) (*api.ActionResponse, error), who identity.ID, body any) map[string]any {
	t.Helper()
	raw, _ := json.Marshal(body)
	resp, err := h(f.ctx, &api.ActionRequest{Caller: api.Caller{ID: who, Kind: "user"}, Body: raw})
	if err != nil {
		t.Fatalf("%v", err)
	}
	var out map[string]any
	_ = json.Unmarshal(resp.Body, &out)
	return out
}

func (f *fixture) fails(h func(context.Context, *api.ActionRequest) (*api.ActionResponse, error), who identity.ID, body any) error {
	raw, _ := json.Marshal(body)
	_, err := h(f.ctx, &api.ActionRequest{Caller: api.Caller{ID: who, Kind: "user"}, Body: raw})
	return err
}

func (f *fixture) get(t *testing.T, h network.Handler, secret string, query url.Values, params map[string]string) (int, map[string]any) {
	t.Helper()
	header := map[string]string{}
	if secret != "" {
		header["Authorization"] = "Bearer " + secret
	}
	if params != nil {
		raw, _ := json.Marshal(params)
		header["x-route-params"] = string(raw)
	}
	resp, err := h(f.ctx, &network.Request{Method: network.MethodGet, Header: header, Query: query})
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	_ = json.Unmarshal(resp.Body, &out)
	return resp.Status, out
}

func TestPostingListingClosingAndDeleting(t *testing.T) {
	f := harness(t)
	posted := f.call(t, f.s.requestCreate, f.ada, map[string]any{"title": "Build our booking flow", "category": "Development", "description": longText,
		"budget_type": "fixed", "budget_amount": 1500, "company": "Acme", "request_id": "r1"})
	view := posted["request"].(map[string]any)
	id := view["id"].(string)
	if view["status"] != "open" || view["budget_amount"] != 1500.0 || view["category"] != "Development" {
		t.Fatalf("posted: %v", view)
	}
	// A retry with the same request id posts once.
	again := f.call(t, f.s.requestCreate, f.ada, map[string]any{"title": "Build our booking flow", "category": "Development", "description": longText,
		"budget_type": "fixed", "budget_amount": 1500, "company": "Acme", "request_id": "r1"})
	if again["request"].(map[string]any)["id"] != id {
		t.Fatal("a retry returns the same request")
	}
	if list := f.call(t, f.s.requestList, f.ada, nil)["requests"].([]any); len(list) != 1 {
		t.Fatalf("one request: %v", list)
	}
	if err := f.fails(f.s.requestCreate, f.ada, map[string]any{"title": "x"}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("an invalid request is refused: %v", err)
	}
	// Someone else cannot touch it.
	bo, _ := identity.New(1)
	_ = f.s.R.CreateID(f.ctx, "accounts", bo, account.New(bo, account.KindUser, "bo", "bo@x.test"))
	if err := f.fails(f.s.requestStatus, bo, map[string]any{"id": id, "status": "closed"}); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("not theirs: %v", err)
	}
	closed := f.call(t, f.s.requestStatus, f.ada, map[string]any{"id": id, "status": "closed"})["request"].(map[string]any)
	if closed["status"] != "closed" {
		t.Fatal("closed")
	}
	f.call(t, f.s.requestStatus, f.ada, map[string]any{"id": id, "status": "open"})
	f.call(t, f.s.requestDelete, f.ada, map[string]any{"id": id})
	if list := f.call(t, f.s.requestList, f.ada, nil)["requests"].([]any); len(list) != 0 {
		t.Fatalf("a deleted request is gone from the poster's list: %v", list)
	}
	if err := f.fails(f.s.requestStatus, f.ada, map[string]any{"id": id, "status": "open"}); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("and cannot be reopened: %v", err)
	}
}

func TestAPersonHasAtMostTenOpenRequests(t *testing.T) {
	f := harness(t)
	post := func(n int) error {
		return f.fails(f.s.requestCreate, f.ada, map[string]any{"title": "Request number " + string(rune('A'+n)), "category": "Design", "description": longText,
			"budget_type": "hourly", "budget_amount": 40, "company": "Acme"})
	}
	for n := 0; n < MaxOpenPerPerson; n++ {
		if err := post(n); err != nil {
			t.Fatalf("request %d: %v", n, err)
		}
	}
	if err := post(MaxOpenPerPerson); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("the eleventh is refused: %v", err)
	}
}

func TestTheAdminTakesDownRequestsAndManagesPartnerKeys(t *testing.T) {
	f := harness(t)
	id := f.call(t, f.s.requestCreate, f.ada, map[string]any{"title": "Build our booking flow", "category": "Development", "description": longText,
		"budget_type": "fixed", "budget_amount": 1500, "company": "Acme"})["request"].(map[string]any)["id"].(string)
	if err := f.fails(f.s.adminRequests, f.ada, nil); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("only the admin: %v", err)
	}
	all := f.call(t, f.s.adminRequests, f.admin, nil)["requests"].([]any)
	if len(all) != 1 || all[0].(map[string]any)["owner_handle"] != "ada" {
		t.Fatalf("the admin sees whose it is: %v", all)
	}
	f.call(t, f.s.adminRequestStatus, f.admin, map[string]any{"id": id, "status": "hidden"})
	if err := f.fails(f.s.requestStatus, f.ada, map[string]any{"id": id, "status": "open"}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("the poster cannot reopen a request that was taken down: %v", err)
	}
	if err := f.fails(f.s.partnerKeyCreate, f.ada, map[string]any{"name": "Partner"}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("only the admin makes keys: %v", err)
	}
	made := f.call(t, f.s.partnerKeyCreate, f.admin, map[string]any{"name": "Acme Jobs"})
	secret := made["secret"].(string)
	if !strings.HasPrefix(secret, partnerKeyPrefix) || made["key"].(map[string]any)["name"] != "Acme Jobs" {
		t.Fatalf("a key: %v", made)
	}
	listed := f.call(t, f.s.partnerKeys, f.admin, nil)["keys"].([]any)
	if len(listed) != 1 || strings.Contains(string(mustJSON(listed)), secret) {
		t.Fatalf("the list never carries the secret: %v", listed)
	}
	keyID := listed[0].(map[string]any)["id"].(string)
	f.call(t, f.s.partnerKeyRevoke, f.admin, map[string]any{"id": keyID})
	if status, _ := f.get(t, f.s.apiList, secret, nil, nil); status != http.StatusUnauthorized {
		t.Fatalf("a revoked key is refused: %d", status)
	}
}

func mustJSON(v any) []byte { b, _ := json.Marshal(v); return b }

func TestPartnersReadTheOpenRequests(t *testing.T) {
	f := harness(t)
	post := func(title, category string) string {
		time.Sleep(2 * time.Millisecond) // distinct creation times, as real posts have
		return f.call(t, f.s.requestCreate, f.ada, map[string]any{"title": title, "category": category, "description": longText, "budget_type": "monthly",
			"budget_amount": 4000, "company": "Acme", "skills": []string{"Go"}})["request"].(map[string]any)["id"].(string)
	}
	a, b, c := post("First request", "Development"), post("Second request", "Design"), post("Third request", "Development")
	secret := f.call(t, f.s.partnerKeyCreate, f.admin, map[string]any{"name": "Partner"})["secret"].(string)

	if status, body := f.get(t, f.s.apiList, "", nil, nil); status != http.StatusUnauthorized || body["error"].(map[string]any)["code"] != "missing_key" {
		t.Fatalf("no key: %d %v", status, body)
	}
	if status, _ := f.get(t, f.s.apiList, partnerKeyPrefix+"nope", nil, nil); status != http.StatusUnauthorized {
		t.Fatalf("a wrong key: %d", status)
	}
	status, body := f.get(t, f.s.apiList, secret, nil, nil)
	data := body["data"].([]any)
	if status != 200 || len(data) != 3 || data[0].(map[string]any)["title"] != "Third request" || body["has_more"] != false {
		t.Fatalf("newest first: %d %v", status, body)
	}
	first := data[0].(map[string]any)
	if first["budget"].(map[string]any)["type"] != "monthly" || first["budget"].(map[string]any)["amount"] != 4000.0 || first["budget"].(map[string]any)["currency"] != "USD" ||
		first["timeline"] != nil || first["status"] != "open" || first["skills"].([]any)[0] != "Go" {
		t.Fatalf("the shape: %v", first)
	}
	if _, leaks := first["owner_id"]; leaks || strings.Contains(string(mustJSON(first)), f.ada.String()) {
		t.Fatalf("partners are not given internal ids: %v", first)
	}
	if poster, _ := first["poster"].(map[string]any); poster["email"] != "ada@x.test" || poster["name"] == "" {
		t.Fatalf("partners are given the poster's name and email: %v", first)
	}
	if _, leaks := first["space_id"]; leaks {
		t.Fatalf("partners are not told the project: %v", first)
	}
	// Pages.
	_, page1 := f.get(t, f.s.apiList, secret, url.Values{"limit": {"2"}}, nil)
	if len(page1["data"].([]any)) != 2 || page1["has_more"] != true || page1["next_cursor"] == nil {
		t.Fatalf("page one: %v", page1)
	}
	_, page2 := f.get(t, f.s.apiList, secret, url.Values{"limit": {"2"}, "cursor": {page1["next_cursor"].(string)}}, nil)
	if d := page2["data"].([]any); len(d) != 1 || d[0].(map[string]any)["title"] != "First request" || page2["has_more"] != false {
		t.Fatalf("page two: %v", page2)
	}
	if status, _ := f.get(t, f.s.apiList, secret, url.Values{"cursor": {"junk!"}}, nil); status != http.StatusBadRequest {
		t.Fatalf("a bad cursor: %d", status)
	}
	// By category.
	if _, d := f.get(t, f.s.apiList, secret, url.Values{"category": {"design"}}, nil); len(d["data"].([]any)) != 1 {
		t.Fatalf("category: %v", d)
	}
	if status, _ := f.get(t, f.s.apiList, secret, url.Values{"category": {"Plumbing"}}, nil); status != http.StatusBadRequest {
		t.Fatalf("an unknown category: %d", status)
	}
	// One request.
	if status, one := f.get(t, f.s.apiGet, secret, nil, map[string]string{"id": b}); status != 200 || one["title"] != "Second request" {
		t.Fatalf("one: %d %v", status, one)
	}

	// What changes: closed and taken-down requests leave the open list, and the changes feed says so.
	since := time.Now().UTC().Format(time.RFC3339Nano)
	time.Sleep(2 * time.Millisecond)
	f.call(t, f.s.requestStatus, f.ada, map[string]any{"id": a, "status": "closed"})
	f.call(t, f.s.adminRequestStatus, f.admin, map[string]any{"id": c, "status": "hidden"})
	if _, open := f.get(t, f.s.apiList, secret, nil, nil); len(open["data"].([]any)) != 1 {
		t.Fatalf("only the second is still open: %v", open)
	}
	if status, _ := f.get(t, f.s.apiGet, secret, nil, map[string]string{"id": a}); status != http.StatusNotFound {
		t.Fatalf("a closed request is not found: %d", status)
	}
	_, changes := f.get(t, f.s.apiList, secret, url.Values{"updated_since": {since}}, nil)
	feed := changes["data"].([]any)
	if len(feed) != 2 || changes["next_updated_since"] == since {
		t.Fatalf("the changes: %v", changes)
	}
	for _, item := range feed {
		m := item.(map[string]any)
		if m["status"] != "closed" || m["title"] != nil || m["description"] != nil {
			t.Fatalf("a closed request is only reported as gone: %v", m)
		}
	}
	if status, _ := f.get(t, f.s.apiList, secret, url.Values{"updated_since": {"yesterday"}}, nil); status != http.StatusBadRequest {
		t.Fatalf("a bad time: %d", status)
	}
}

func TestAKeyIsRateLimited(t *testing.T) {
	f := harness(t)
	secret := f.call(t, f.s.partnerKeyCreate, f.admin, map[string]any{"name": "Partner"})["secret"].(string)
	var last int
	for n := 0; n <= partnerRate; n++ {
		last, _ = f.get(t, f.s.apiList, secret, nil, nil)
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("over the limit: %d", last)
	}
}

// The partner routes are reachable where partners are told to look: the
// developer host's /v1/partner/talent-requests, and nowhere else by that name.
func TestThePartnerAPIIsServedOnTheDeveloperHost(t *testing.T) {
	f := harness(t)
	f.call(t, f.s.requestCreate, f.ada, map[string]any{"title": "Build our booking flow", "category": "Development", "description": longText,
		"budget_type": "fixed", "budget_amount": 1500, "company": "Acme"})
	secret := f.call(t, f.s.partnerKeyCreate, f.admin, map[string]any{"name": "Partner"})["secret"].(string)
	a := nethttp.New(logger.Global())
	probe, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := probe.Addr().String()
	_ = probe.Close()
	_ = a.Open(f.ctx, network.Config{Addr: addr, Options: map[string]string{"developer_host": "api.test"}})
	if err := f.s.Register(a); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(f.ctx)
	defer cancel()
	go func() { _ = a.Serve(ctx) }()
	for i := 0; i < 50; i++ {
		if c, err := net.Dial("tcp", addr); err == nil {
			_ = c.Close()
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	do := func(host, path, key string) (int, string) {
		req, _ := http.NewRequest("GET", "http://"+addr+path, nil)
		req.Host = host
		if key != "" {
			req.Header.Set("Authorization", "Bearer "+key)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		raw, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(raw)
	}
	status, body := do("api.test", "/v1/partner/talent-requests?limit=5", secret)
	if status != 200 || !strings.Contains(body, "Build our booking flow") || strings.Contains(body, f.ada.String()) {
		t.Fatalf("list: %d %s", status, body)
	}
	var list struct {
		Data []struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	_ = json.Unmarshal([]byte(body), &list)
	if status, body := do("api.test", "/v1/partner/talent-requests/"+list.Data[0].ID, secret); status != 200 || !strings.Contains(body, "booking") {
		t.Fatalf("one: %d %s", status, body)
	}
	if status, _ := do("api.test", "/v1/partner/talent-requests", ""); status != 401 {
		t.Fatalf("no key: %d", status)
	}
	// The node's own host does not serve it under that name.
	if status, _ := do("app.test", "/v1/partner/talent-requests", secret); status == 200 {
		t.Fatalf("not on the app's host: %d", status)
	}
}
