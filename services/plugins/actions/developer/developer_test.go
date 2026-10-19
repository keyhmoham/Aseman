package developer

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/finance/models/wallet"
	"github.com/tradera/tradera/plugins/actions/llm/dto"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/memory"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	nethttp "github.com/tradera/tradera/plugins/adapters/network/http"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
	dbmodel "github.com/tradera/tradera/plugins/testutil"
)

// fakeFinance keeps balances in memory and records every charge.
type fakeFinance struct {
	mu      sync.Mutex
	balance map[identity.ID]int64
	charges []wallet.ChargeLine
	billed  map[identity.ID]int64
	// chargeErr, when set, refuses every charge.
	chargeErr error
}

func newFinance() *fakeFinance {
	return &fakeFinance{balance: map[identity.ID]int64{}, billed: map[identity.ID]int64{}}
}

func (f *fakeFinance) EnsureWallet(_ context.Context, owner identity.ID) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.balance[owner]; !ok {
		f.balance[owner] = 0
	}
	return nil
}
func (f *fakeFinance) GetWallet(_ context.Context, owner identity.ID) (*wallet.Wallet, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	b, ok := f.balance[owner]
	if !ok {
		return nil, errs.NotFound("wallet")
	}
	return &wallet.Wallet{OwnerID: owner, Balance: b}, nil
}
func (f *fakeFinance) Transfer(_ context.Context, from, to identity.ID, amount int64) (*wallet.LedgerEntry, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.balance[from] < amount {
		return nil, errs.New(errs.CodeFinance, "insufficient balance")
	}
	f.balance[from] -= amount
	f.balance[to] += amount
	return &wallet.LedgerEntry{Amount: amount}, nil
}
func (f *fakeFinance) EnsureFunds(_ context.Context, customer identity.ID, min int64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.balance[customer] < min {
		return errs.New(errs.CodeFinance, "insufficient balance")
	}
	return nil
}
func (f *fakeFinance) ChargeLines(_ context.Context, customer identity.ID, _ string, lines []wallet.ChargeLine) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.chargeErr != nil {
		return f.chargeErr
	}
	for _, l := range lines {
		f.balance[customer] -= l.Amount
		f.billed[customer] += l.Amount
		f.charges = append(f.charges, l)
		if len(l.Payees) > 0 { // as the ledger does: the payee is paid
			f.balance[l.Payees[0]] += l.Amount
		}
	}
	return nil
}

type fakeProviders struct{ list []dto.Offering }

func (p fakeProviders) Offerings(context.Context) ([]dto.Offering, error) { return p.list, nil }

// scripted answers provider calls by host.
type scripted struct {
	mu      sync.Mutex
	handler func(r *http.Request, body []byte) (int, string, string)
	calls   []string
	bodies  []map[string]any
}

func (d *scripted) Do(r *http.Request) (*http.Response, error) {
	raw, _ := io.ReadAll(r.Body)
	var parsed map[string]any
	_ = json.Unmarshal(raw, &parsed)
	d.mu.Lock()
	d.calls = append(d.calls, r.URL.Host+r.URL.Path)
	d.bodies = append(d.bodies, parsed)
	d.mu.Unlock()
	status, ctype, body := d.handler(r, raw)
	return &http.Response{StatusCode: status, Header: http.Header{"Content-Type": {ctype}}, Body: io.NopCloser(strings.NewReader(body))}, nil
}

const ok = `{"id":"c1","choices":[{"index":0,"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1000,"completion_tokens":500}}`

type fixture struct {
	s    *Service
	ctx  context.Context
	fin  *fakeFinance
	http *scripted
	me   identity.ID
	now  time.Time
}

func offering(slug, kind, model string, def bool, in, out float64, owner identity.ID) dto.Offering {
	return dto.Offering{Provider: slug + "-id", Slug: slug, Name: strings.ToUpper(slug), Kind: kind, IsDefault: def, Owner: owner,
		BaseURL: "https://" + slug + ".test/v1", APIKey: "key-" + slug, Model: model, Type: "chat", InputPrice: in, OutputPrice: out}
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
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global()})
	f := &fixture{ctx: ctx, fin: newFinance(), http: &scripted{}, now: time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)}
	f.http.handler = func(*http.Request, []byte) (int, string, string) { return 200, "application/json", ok }
	owner, _ := identity.New(1)
	f.me = f.person(t, db, "ada")
	s := NewService(k, &repo.Repo{DB: db}, logger.Global())
	s.Fin, s.HTTP, s.Now = f.fin, f.http, func() time.Time { return f.now }
	s.Providers = fakeProviders{list: []dto.Offering{
		offering("vertex", "vertex", "gemini-3.8-flash", true, 300_000, 1_200_000, owner),
		offering("openrouter", "openrouter", "google/gemini-3.8-flash", false, 320_000, 1_280_000, owner),
		offering("openai", "openai", "gpt-5-mini", true, 250_000, 2_000_000, owner),
	}}
	f.s = s
	f.fin.balance[f.me] = 50_000_000 // $50
	return f
}

func (f *fixture) person(t *testing.T, db database.Database, handle string) identity.ID {
	t.Helper()
	id, _ := identity.New(1)
	acc := account.New(id, account.KindUser, handle, handle+"@x.test")
	if err := (&repo.Repo{DB: db}).CreateID(context.Background(), "accounts", id, acc); err != nil {
		t.Fatal(err)
	}
	return id
}

func (f *fixture) key(t *testing.T, sc Scope, in KeyInput) (*Principal, string) {
	t.Helper()
	view, secret, err := f.s.CreateKey(f.ctx, f.me, sc, in)
	if err != nil {
		t.Fatal(err)
	}
	if view.Prefix+"…"+view.Last4 == "" || !strings.HasPrefix(secret, KeyPrefix) {
		t.Fatalf("bad key %+v", view)
	}
	p, err := f.s.Authenticate(f.ctx, secret)
	if err != nil {
		t.Fatal(err)
	}
	return p, secret
}

var all = Permissions{Models: LevelRead, Chat: LevelWrite, Computers: LevelWrite, Files: LevelWrite, Usage: LevelRead}

func (f *fixture) personal(t *testing.T) Scope {
	t.Helper()
	sc, err := f.s.Scope(f.ctx, f.me, "personal")
	if err != nil {
		t.Fatal(err)
	}
	return sc
}

func chatCall(p *Principal, model string) Call {
	return Call{Principal: p, Org: p.Org, KeyID: p.Key.ID.String(), KeyName: p.Key.Name, Type: TypeLanguage, Model: model,
		Body: map[string]any{"messages": []any{map[string]any{"role": "user", "content": "hi"}}}}
}

func errCode(r *Result) string {
	var body struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	_ = json.Unmarshal(r.Body, &body)
	return body.Error.Code
}

func TestOrganizationsKeepPeopleAndRolesApart(t *testing.T) {
	f := harness(t)
	team, err := f.s.CreateOrg(f.ctx, f.me, "Acme")
	if err != nil || team.Role != "owner" {
		t.Fatalf("create: %v %+v", err, team)
	}
	if _, err := f.s.CreateOrg(f.ctx, f.me, "acme"); errs.CodeOf(err) != errs.CodeAlreadyExists {
		t.Fatalf("a duplicate name must be refused: %v", err)
	}
	if _, ok := f.fin.balance[mustID(t, team.ID)]; !ok {
		t.Fatal("an organization gets a wallet of its own")
	}
	sc, _ := f.s.Scope(f.ctx, f.me, team.ID)
	bob := f.person(t, f.s.R.DB, "bob")
	if _, err := f.s.Invite(f.ctx, f.me, sc, "@Bob", "developer"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.s.Invite(f.ctx, f.me, sc, "bob", "viewer"); errs.CodeOf(err) != errs.CodeAlreadyExists {
		t.Fatalf("inviting twice: %v", err)
	}
	if _, err := f.s.Invite(f.ctx, f.me, sc, "nobody", "viewer"); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("an unknown username: %v", err)
	}
	// Until bob accepts, the organization does not exist for him.
	if _, err := f.s.Scope(f.ctx, bob, team.ID); err == nil {
		t.Fatal("an invited person is not a member yet")
	}
	invites, _ := f.s.Invites(f.ctx, bob)
	if len(invites) != 1 || invites[0].Name != "Acme" || invites[0].InvitedBy != "ada" {
		t.Fatalf("invites: %+v", invites)
	}
	if err := f.s.Respond(f.ctx, bob, team.ID, true); err != nil {
		t.Fatal(err)
	}
	bsc, err := f.s.Scope(f.ctx, bob, team.ID)
	if err != nil || bsc.Role != "developer" {
		t.Fatalf("bob: %v %+v", err, bsc)
	}
	// A developer makes keys but cannot manage people or money.
	if _, _, err := f.s.CreateKey(f.ctx, bob, bsc, KeyInput{Name: "bob's"}); err != nil {
		t.Fatalf("a developer may create keys: %v", err)
	}
	if _, err := f.s.Invite(f.ctx, bob, bsc, "ada", "viewer"); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a developer may not invite: %v", err)
	}
	if _, err := f.s.Fund(f.ctx, bob, bsc, 1_000_000); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a developer may not fund: %v", err)
	}
	// The last owner cannot leave or be demoted.
	members, _ := f.s.Members(f.ctx, f.me, sc)
	var mine string
	for _, m := range members {
		if m.You {
			mine = m.ID
		}
	}
	if err := f.s.RemoveMember(f.ctx, f.me, sc, mine); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("the last owner must stay: %v", err)
	}
	if err := f.s.SetRole(f.ctx, sc, mine, "viewer"); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("the last owner must keep the role: %v", err)
	}
	// Keys belong to the organization they were made in.
	if keys, _ := f.s.Keys(f.ctx, f.personal(t)); len(keys) != 0 {
		t.Fatalf("personal keys: %+v", keys)
	}
	if keys, _ := f.s.Keys(f.ctx, sc); len(keys) != 1 {
		t.Fatalf("team keys: %+v", keys)
	}
}

func mustID(t *testing.T, s string) identity.ID {
	t.Helper()
	id, err := identity.Parse(s)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func TestFundingAndDeletingAnOrganization(t *testing.T) {
	f := harness(t)
	team, _ := f.s.CreateOrg(f.ctx, f.me, "Funds")
	sc, _ := f.s.Scope(f.ctx, f.me, team.ID)
	if _, err := f.s.Fund(f.ctx, f.me, f.personal(t), 1_000_000); err == nil {
		t.Fatal("the personal organization is funded in Billing, not here")
	}
	if _, err := f.s.Fund(f.ctx, f.me, sc, 100); err == nil {
		t.Fatal("a tiny amount must be refused")
	}
	view, err := f.s.Fund(f.ctx, f.me, sc, 20_000_000)
	if err != nil || view.Balance != 20_000_000 || f.fin.balance[f.me] != 30_000_000 {
		t.Fatalf("fund: %v %+v personal=%d", err, view, f.fin.balance[f.me])
	}
	if _, err := f.s.Fund(f.ctx, f.me, sc, 999_000_000); errs.CodeOf(err) != errs.CodeFinance {
		t.Fatalf("more than the person has: %v", err)
	}
	if err := f.s.DeleteOrg(f.ctx, f.me, sc); err != nil {
		t.Fatal(err)
	}
	if f.fin.balance[f.me] != 50_000_000 {
		t.Fatalf("what is left goes back to the person: %d", f.fin.balance[f.me])
	}
	if _, err := f.s.Scope(f.ctx, f.me, team.ID); err == nil {
		t.Fatal("a deleted organization is gone")
	}
}

func TestKeysAuthenticateAndAreLimited(t *testing.T) {
	f := harness(t)
	sc := f.personal(t)
	p, secret := f.key(t, sc, KeyInput{Name: "ci", Permissions: Permissions{Models: LevelRead, Chat: LevelWrite}, Limits: Limits{RPM: 2, MonthlyCap: 1_000}})
	view, _ := f.s.Keys(f.ctx, sc)
	if len(view) != 1 || strings.Contains(jsonOf(view), secret) {
		t.Fatal("the listing never carries the secret")
	}
	if p.Org != f.me || p.OrgName != "Personal" {
		t.Fatalf("a personal key belongs to the person's account: %+v", p)
	}
	if err := p.Need("computers", LevelRead); err == nil {
		t.Fatal("a permission the key lacks must be refused")
	}
	if err := p.Need("chat", LevelWrite); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{"", "sk-nope", KeyPrefix + "wrong"} {
		if _, err := f.s.Authenticate(f.ctx, bad); err == nil {
			t.Fatalf("%q must not authenticate", bad)
		}
	}
	if _, _, _, ok := f.s.Allow(p); !ok {
		t.Fatal("first request")
	}
	if _, rem, _, ok := f.s.Allow(p); !ok || rem != 0 {
		t.Fatal("second request uses the last")
	}
	if _, _, retry, ok := f.s.Allow(p); ok || retry < 1 {
		t.Fatal("the third request in the minute is limited")
	}
	f.now = f.now.Add(61 * time.Second)
	if _, _, _, ok := f.s.Allow(p); !ok {
		t.Fatal("the window moves on")
	}
	f.s.recordUse(f.ctx, p, 1_500)
	p, _ = f.s.Authenticate(f.ctx, secret)
	if err := f.s.SpendCheck(f.ctx, p); err == nil {
		t.Fatal("a key over its monthly cap is stopped")
	}
	f.now = time.Date(2026, 11, 2, 0, 0, 0, 0, time.UTC)
	if err := f.s.SpendCheck(f.ctx, p); err != nil {
		t.Fatalf("the cap resets with the month: %v", err)
	}
	if err := f.s.RevokeKey(f.ctx, sc, view[0].ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.s.Authenticate(f.ctx, secret); err == nil {
		t.Fatal("a revoked key stops at once")
	}
	exp, secret2 := f.key(t, sc, KeyInput{Name: "temp", Limits: Limits{ExpiresAt: f.now.Add(time.Hour).Format(time.RFC3339)}})
	_ = exp
	f.now = f.now.Add(2 * time.Hour)
	if _, err := f.s.Authenticate(f.ctx, secret2); err == nil {
		t.Fatal("an expired key stops")
	}
}

func jsonOf(v any) string { b, _ := json.Marshal(v); return string(b) }

func TestCatalogMergesAProviderlessModelAcrossProviders(t *testing.T) {
	f := harness(t)
	catalog, err := f.s.Catalog(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	m := FindModel(catalog, "gemini-3.8-flash")
	if m == nil || m.ID != "google/gemini-3.8-flash" {
		t.Fatalf("one entry under its creator: %+v", m)
	}
	if len(m.Endpoints) != 2 || m.Endpoints[0].Provider != "vertex" || !m.Endpoints[0].IsDefault || m.Endpoints[1].IsDefault {
		t.Fatalf("both providers, the default first: %+v", m.Endpoints)
	}
	if FindModel(catalog, "openai/gpt-5-mini") == nil || FindModel(catalog, "google/gemini-3.8-flash").Type != TypeLanguage {
		t.Fatal("other models and types")
	}
	if got := len(catalog); got != 2 {
		t.Fatalf("two distinct models, got %d", got)
	}
}

func TestRoutePlanner(t *testing.T) {
	f := harness(t)
	catalog, _ := f.s.Catalog(f.ctx)
	names := func(p Plan) string {
		var out []string
		for _, a := range p.Attempts {
			out = append(out, a.Model.ID+"@"+a.Endpoint.Provider)
		}
		return strings.Join(out, ",")
	}
	flash := "google/gemini-3.8-flash"
	if got := names(PlanRoute(catalog, flash, RouteOptions{}, nil)); got != flash+"@vertex,"+flash+"@openrouter" {
		t.Fatalf("default first: %s", got)
	}
	if got := names(PlanRoute(catalog, flash, RouteOptions{Order: []string{"openrouter"}}, nil)); got != flash+"@openrouter,"+flash+"@vertex" {
		t.Fatalf("order: %s", got)
	}
	if got := names(PlanRoute(catalog, flash, RouteOptions{Only: []string{"openrouter"}}, nil)); got != flash+"@openrouter" {
		t.Fatalf("only: %s", got)
	}
	if got := names(PlanRoute(catalog, flash, RouteOptions{Ignore: []string{"vertex"}}, nil)); got != flash+"@openrouter" {
		t.Fatalf("ignore: %s", got)
	}
	no := false
	if got := names(PlanRoute(catalog, flash, RouteOptions{Order: []string{"openrouter"}, AllowFallbacks: &no}, nil)); got != flash+"@openrouter" {
		t.Fatalf("no fallbacks: %s", got)
	}
	if got := PlanRoute(catalog, flash+":floor", RouteOptions{}, nil).Attempts[0].Endpoint.Provider; got != "vertex" {
		t.Fatalf(":floor is the cheapest: %s", got)
	}
	cap := 310_000.0
	if got := names(PlanRoute(catalog, flash, RouteOptions{MaxPrice: &MaxPrice{Input: &cap}}, nil)); got != flash+"@vertex" {
		t.Fatalf("max price: %s", got)
	}
	if got := names(PlanRoute(catalog, "nope/unknown", RouteOptions{}, []string{"gpt-5-mini"})); got != "openai/gpt-5-mini@openai" {
		t.Fatalf("an unknown model is skipped for the next: %s", got)
	}
	if plan := PlanRoute(catalog, flash, RouteOptions{Only: []string{"nowhere"}}, nil); plan.Err == "" {
		t.Fatal("nothing left to try is an error")
	}
	req, _ := parseProvider(map[string]any{"max_price": map[string]any{"input": 0.5}, "sort": "price", "order": []any{"vertex"}})
	if req.Sort != "price" || *req.MaxPrice.Input != 500_000 || req.Order[0] != "vertex" {
		t.Fatalf("the API's max_price is dollars: %+v", req)
	}
	if _, bad := parseProvider(map[string]any{"sort": "vibes"}); bad == "" {
		t.Fatal("an unknown sort is refused")
	}
}

func TestChatIsRoutedBilledAndLogged(t *testing.T) {
	f := harness(t)
	p, _ := f.key(t, f.personal(t), KeyInput{Name: "app", Permissions: all})
	res := f.s.Execute(f.ctx, chatCall(p, "google/gemini-3.8-flash"))
	if res.Status != 200 || res.Provider != "vertex" || res.Model != "google/gemini-3.8-flash" {
		t.Fatalf("%d %s", res.Status, res.Body)
	}
	// 1000 in at $0.30/M + 500 out at $1.20/M = $0.0009 = 900 units.
	if res.Cost != 900 || f.fin.billed[f.me] != 900 || len(f.fin.charges) != 1 || f.fin.charges[0].Type != wallet.EntryPayLLM {
		t.Fatalf("cost %d billed %v %+v", res.Cost, f.fin.billed, f.fin.charges)
	}
	var body map[string]any
	_ = json.Unmarshal(res.Body, &body)
	if _, named := body["provider"]; named || body["model"] != "google/gemini-3.8-flash" || body["usage"].(map[string]any)["cost"] != 0.0009 {
		t.Fatalf("the reply names the model that answered (not the provider) and the cost in dollars: %v", body)
	}
	if !strings.Contains(f.http.calls[0], "vertex.test") || f.http.bodies[0]["model"] != "google/gemini-3.8-flash" {
		t.Fatalf("upstream: %v %v", f.http.calls, f.http.bodies)
	}
	logs, _ := f.s.Logs(f.ctx, f.me, LogFilter{}, 10)
	if len(logs) != 1 || logs[0].Provider != "" || logs[0].Cost != 900 || logs[0].Path != "/v1/chat/completions" || logs[0].TokensIn != 1000 {
		t.Fatalf("logs (the developer is not told the provider): %+v", logs)
	}
	if seen, _ := f.s.AdminLogs(f.ctx, "", LogFilter{}, 10); len(seen) != 1 || seen[0].Provider != "vertex" || seen[0].Org != f.me.String() {
		t.Fatalf("the admin sees whose request it was and which provider served it: %+v", seen)
	}
	keys, _ := f.s.Keys(f.ctx, f.personal(t))
	if keys[0].Requests != 1 || keys[0].SpentMonth != 900 {
		t.Fatalf("the key counts its use: %+v", keys[0])
	}
}

func TestChatFailsOverButNeverRetriesABadRequest(t *testing.T) {
	f := harness(t)
	p, _ := f.key(t, f.personal(t), KeyInput{Name: "app", Permissions: all})
	f.http.handler = func(r *http.Request, _ []byte) (int, string, string) {
		if strings.Contains(r.URL.Host, "vertex") {
			return 503, "application/json", `{"error":{"message":"overloaded"}}`
		}
		return 200, "application/json", ok
	}
	res := f.s.Execute(f.ctx, chatCall(p, "gemini-3.8-flash"))
	if res.Status != 200 || res.Provider != "openrouter" {
		t.Fatalf("the next provider answers: %d %s", res.Status, res.Body)
	}
	if len(res.Skipped) != 1 || res.Skipped[0].Provider != "vertex" || res.Skipped[0].Status != 503 {
		t.Fatalf("skipped: %+v", res.Skipped)
	}
	// With fallbacks off, the one provider's failure is the answer.
	no := false
	c := chatCall(p, "gemini-3.8-flash")
	c.Route = RouteOptions{AllowFallbacks: &no}
	if r := f.s.Execute(f.ctx, c); r.Status != 502 || errCode(r) != "model_unavailable" || strings.Contains(string(r.Body), "vertex") {
		t.Fatalf("no fallbacks: %d %s", r.Status, r.Body)
	}
	// A refused request is the same everywhere: no second try.
	f.http.calls = nil
	f.http.handler = func(*http.Request, []byte) (int, string, string) {
		return 400, "application/json", `{"error":{"message":"bad messages"}}`
	}
	r := f.s.Execute(f.ctx, chatCall(p, "gemini-3.8-flash"))
	if r.Status != 400 || len(f.http.calls) != 1 || !strings.Contains(string(r.Body), "bad messages") {
		t.Fatalf("%d calls=%v %s", r.Status, f.http.calls, r.Body)
	}
	// A fallback model answers when the first model has no provider left.
	f.http.handler = func(*http.Request, []byte) (int, string, string) { return 200, "application/json", ok }
	c = chatCall(p, "gemini-3.8-flash")
	c.Route = RouteOptions{Only: []string{"vertex"}}
	c.Fallbacks = []string{"gpt-5-mini"}
	if r := f.s.Execute(f.ctx, c); r.Status != 200 || r.Model != "google/gemini-3.8-flash" {
		t.Fatalf("%d %s", r.Status, r.Body)
	}
}

func TestChatRefusalsCostNothing(t *testing.T) {
	f := harness(t)
	p, _ := f.key(t, f.personal(t), KeyInput{Name: "narrow", Permissions: all, Limits: Limits{Models: []string{"openai/gpt-5-mini"}, Providers: []string{"openai"}}})
	if r := f.s.Execute(f.ctx, chatCall(p, "google/gemini-3.8-flash")); r.Status != 403 || errCode(r) != "model_not_allowed" {
		t.Fatalf("a model outside the key's list: %d %s", r.Status, r.Body)
	}
	if r := f.s.Execute(f.ctx, chatCall(p, "gpt-5-mini")); r.Status != 200 {
		t.Fatalf("the allowed one works: %d %s", r.Status, r.Body)
	}
	f.fin.charges, f.fin.billed = nil, map[identity.ID]int64{}
	if r := f.s.Execute(f.ctx, chatCall(p, "nothing/here")); r.Status != 404 || errCode(r) != "model_not_found" {
		t.Fatalf("%d %s", r.Status, r.Body)
	}
	wide, _ := f.key(t, f.personal(t), KeyInput{Name: "wide", Permissions: all})
	img := chatCall(wide, "gpt-5-mini")
	img.Type = TypeImage
	if r := f.s.Execute(f.ctx, img); r.Status != 400 || errCode(r) != "wrong_model_type" {
		t.Fatalf("a language model on the images endpoint: %d %s", r.Status, r.Body)
	}
	readOnly, _ := f.key(t, f.personal(t), KeyInput{Name: "ro", Permissions: Permissions{Models: LevelRead}})
	if r := f.s.Execute(f.ctx, chatCall(readOnly, "gpt-5-mini")); r.Status != 403 {
		t.Fatalf("a key without chat access: %d", r.Status)
	}
	f.fin.balance[f.me] = 0
	if r := f.s.Execute(f.ctx, chatCall(wide, "gpt-5-mini")); r.Status != 402 || errCode(r) != "insufficient_funds" {
		t.Fatalf("an empty balance: %d %s", r.Status, r.Body)
	}
	if len(f.fin.charges) != 0 {
		t.Fatalf("refusals are free: %+v", f.fin.charges)
	}
}

func TestDecisionModelIsListedRoutedBilledAndLogged(t *testing.T) {
	f := harness(t)
	owner, _ := identity.New(1)
	jev := offering("vercel", "vercel", "typesafe-ai/jev", false, 42_000, 0, owner)
	jev.Type = "decision"
	f.s.Providers = fakeProviders{list: append(f.s.Providers.(fakeProviders).list, jev)}
	f.http.handler = func(*http.Request, []byte) (int, string, string) {
		return 200, "application/json", `{"model":"typesafe-ai/jev","answers":{"escalate":{"type":"boolean","probability":0.97}},"usage":{"inputTokens":2000000,"outputTokens":0}}`
	}
	p, _ := f.key(t, f.personal(t), KeyInput{Name: "app", Permissions: all})
	catalog, err := f.s.Catalog(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	m := FindModel(catalog, "typesafe-ai/jev")
	if m == nil || m.Type != TypeDecision || len(m.Endpoints) != 1 {
		t.Fatalf("a decision model is in the catalog: %+v", m)
	}
	body := map[string]any{"state": "The customer was charged twice.", "questions": map[string]any{"escalate": map[string]any{"type": "boolean", "instructions": "Escalate?"}}}
	c, bad := parseCall(TypeDecision, map[string]any{"model": "typesafe-ai/jev", "state": body["state"], "questions": body["questions"]})
	if bad != "" {
		t.Fatal(bad)
	}
	c.Principal, c.Org, c.KeyID, c.KeyName = p, p.Org, p.Key.ID.String(), p.Key.Name
	res := f.s.Execute(f.ctx, c)
	if res.Status != 200 || res.Provider != "vercel" || res.Model != "typesafe-ai/jev" {
		t.Fatalf("%d %s", res.Status, res.Body)
	}
	// 2M input tokens at $0.042/M = $0.084 = 84,000 units.
	if res.Cost != 84_000 || f.fin.billed[f.me] != 84_000 {
		t.Fatalf("cost %d billed %v", res.Cost, f.fin.billed)
	}
	if !strings.HasSuffix(f.http.calls[len(f.http.calls)-1], "vercel.test/v1/evaluate") || f.http.bodies[len(f.http.bodies)-1]["model"] != "typesafe-ai/jev" {
		t.Fatalf("upstream: %v", f.http.calls)
	}
	var reply map[string]any
	_ = json.Unmarshal(res.Body, &reply)
	if _, named := reply["provider"]; reply["answers"] == nil || named || reply["usage"].(map[string]any)["cost"] != 0.084 {
		t.Fatalf("the reply keeps the answers and adds the cost, not the provider: %v", reply)
	}
	logs, _ := f.s.Logs(f.ctx, f.me, LogFilter{}, 10)
	if len(logs) != 1 || logs[0].Path != "/v1/decisions" || logs[0].TokensIn != 2_000_000 {
		t.Fatalf("logs: %+v", logs)
	}
	if _, bad := parseCall(TypeDecision, map[string]any{"model": "typesafe-ai/jev", "state": "x"}); bad == "" {
		t.Fatal("a decision without questions is refused")
	}
	if _, bad := parseCall(TypeDecision, map[string]any{"model": "typesafe-ai/jev", "questions": body["questions"]}); bad == "" {
		t.Fatal("a decision without a state is refused")
	}
	chat := chatCall(p, "typesafe-ai/jev")
	if r := f.s.Execute(f.ctx, chat); r.Status != 400 || errCode(r) != "wrong_model_type" || !strings.Contains(string(r.Body), "/v1/decisions") {
		t.Fatalf("a decision model on the chat endpoint: %d %s", r.Status, r.Body)
	}
}

func TestStreamingPassesEventsOnAndBillsAtTheEnd(t *testing.T) {
	f := harness(t)
	p, _ := f.key(t, f.personal(t), KeyInput{Name: "app", Permissions: all})
	f.http.handler = func(*http.Request, []byte) (int, string, string) {
		return 200, "text/event-stream", "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n: keep-alive\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":1000,\"completion_tokens\":500}}\n\ndata: [DONE]\n\n"
	}
	c := chatCall(p, "gemini-3.8-flash")
	c.Stream = true
	res := f.s.Execute(f.ctx, c)
	if res.Status != 200 || res.Stream == nil || res.Header["Content-Type"] != "text/event-stream" || res.Header["X-Tradera-Model"] != "google/gemini-3.8-flash" || res.Header["X-Tradera-Provider"] != "" {
		t.Fatalf("%+v", res)
	}
	if opts, _ := f.http.bodies[0]["stream_options"].(map[string]any); opts["include_usage"] != true {
		t.Fatalf("usage is always asked for: %v", f.http.bodies[0])
	}
	if len(f.fin.charges) != 0 {
		t.Fatal("nothing is billed before the stream is read")
	}
	var out bytes.Buffer
	if err := res.Stream(f.ctx, &out); err != nil {
		t.Fatal(err)
	}
	text := out.String()
	if strings.Contains(text, "vertex") {
		t.Fatalf("the stream does not name the provider: %s", text)
	}
	for _, want := range []string{`"content":"Hel"`, `"content":"lo"`, `"model":"google/gemini-3.8-flash"`, `"cost":0.0009`, ": keep-alive", "data: [DONE]"} {
		if !strings.Contains(text, want) {
			t.Fatalf("missing %q in\n%s", want, text)
		}
	}
	if f.fin.billed[f.me] != 900 {
		t.Fatalf("billed %d", f.fin.billed[f.me])
	}
	logs, _ := f.s.Logs(f.ctx, f.me, LogFilter{}, 5)
	if len(logs) != 1 || logs[0].Cost != 900 || logs[0].Response == nil {
		t.Fatalf("logs %+v", logs)
	}
}

func TestTheHTTPDoorAuthenticatesLimitsAndRoutes(t *testing.T) {
	f := harness(t)
	_, secret := f.key(t, f.personal(t), KeyInput{Name: "web", Permissions: all, Limits: Limits{RPM: 3}})
	call := func(method network.Method, path, token string, body string) *network.Response {
		var handler network.Handler
		for _, r := range f.s.routes() {
			if r.method == method && matchPattern(r.pattern, apiPrefix+path) {
				handler = r.handler
				break
			}
		}
		if handler == nil {
			t.Fatalf("no route for %s %s", method, path)
		}
		req := &network.Request{Method: method, Path: apiPrefix + path, Header: map[string]string{}, Body: []byte(body), Query: map[string][]string{}}
		if token != "" {
			req.Header["Authorization"] = "Bearer " + token
		}
		if i := strings.Index(path, "?"); i >= 0 {
			req.Path = apiPrefix + path[:i]
		}
		parts := strings.Split(strings.TrimPrefix(path, "/models/"), "/")
		if strings.HasPrefix(path, "/models/") && len(parts) >= 2 {
			b, _ := json.Marshal(map[string]string{"creator": parts[0], "name": parts[1]})
			req.Header["x-route-params"] = string(b)
		}
		resp, err := handler(f.ctx, req)
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}
	if r := call(network.MethodGet, "/models", "", ""); r.Status != 401 {
		t.Fatalf("no key: %d", r.Status)
	}
	r := call(network.MethodGet, "/models", secret, "")
	var list struct {
		Data []map[string]any `json:"data"`
	}
	_ = json.Unmarshal(r.Body, &list)
	if r.Status != 200 || len(list.Data) != 2 || r.Header["X-RateLimit-Limit"] != "3" {
		t.Fatalf("%d %s %v", r.Status, r.Body, r.Header)
	}
	flash := list.Data[0]
	if flash["id"] != "google/gemini-3.8-flash" || flash["providers"] != nil {
		t.Fatalf("one model, priced, without a providers list: %v", flash)
	}
	pricing := flash["pricing"].([]any)[0].(map[string]any)
	if pricing["usd"] != 0.3 || pricing["per"] != "1M tokens" {
		t.Fatalf("the default provider's price, in dollars: %v", pricing)
	}
	one := call(network.MethodGet, "/models/google/gemini-3.8-flash", secret, "")
	if one.Status != 200 || !strings.Contains(string(one.Body), `"pricing"`) {
		t.Fatalf("one model: %d %s", one.Status, one.Body)
	}
	chat := call(network.MethodPost, "/chat/completions", secret, `{"model":"gpt-5-mini","messages":[{"role":"user","content":"hi"}],"provider":{"only":["openai"]},"models":["google/gemini-3.8-flash"]}`)
	if chat.Status != 429 && chat.Status != 200 {
		t.Fatalf("chat: %d %s", chat.Status, chat.Body)
	}
	bad := call(network.MethodPost, "/chat/completions", secret, `{"messages":[]}`)
	if bad.Status != 429 && bad.Status != 400 {
		t.Fatalf("a request without a model: %d %s", bad.Status, bad.Body)
	}
	limited := call(network.MethodGet, "/balance", secret, "")
	if limited.Status != 429 || limited.Header["Retry-After"] == "" {
		t.Fatalf("the fourth request in a minute: %d", limited.Status)
	}
	f.now = f.now.Add(2 * time.Minute)
	bal := call(network.MethodGet, "/balance", secret, "")
	if bal.Status != 200 || !strings.Contains(string(bal.Body), `"available":49.`) {
		t.Fatalf("balance: %d %s", bal.Status, bal.Body)
	}
	if v := call(network.MethodPost, "/videos/generations", secret, `{}`); v.Status != 429 && v.Status != 400 {
		t.Fatalf("video: %d", v.Status)
	}
}

func matchPattern(pattern, path string) bool {
	a, b := strings.Split(pattern, "/"), strings.Split(path, "/")
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !(strings.HasPrefix(a[i], "{") || a[i] == b[i]) {
			return false
		}
	}
	return true
}

func TestUsageGroupsByDayModelProviderAndKey(t *testing.T) {
	f := harness(t)
	p, _ := f.key(t, f.personal(t), KeyInput{Name: "app", Permissions: all})
	for _, model := range []string{"gemini-3.8-flash", "gemini-3.8-flash", "gpt-5-mini"} {
		if r := f.s.Execute(f.ctx, chatCall(p, model)); r.Status != 200 {
			t.Fatalf("%d %s", r.Status, r.Body)
		}
	}
	f.now = f.now.Add(26 * time.Hour)
	f.s.Execute(f.ctx, chatCall(p, "gemini-3.8-flash"))
	u, err := f.s.Usage(f.ctx, f.me, 7, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(u.Days) != 7 || u.Total.Requests != 4 || u.Days[5].Requests != 3 || u.Days[6].Requests != 1 {
		t.Fatalf("days: %+v total %+v", u.Days, u.Total)
	}
	if u.ByModel[0].Name != "google/gemini-3.8-flash" || u.ByModel[0].Requests != 3 || u.ByProvider[0].Name != "vertex" || len(u.ByKey) != 1 || u.ByService[0].Name != "Models" {
		t.Fatalf("groups: %+v", u)
	}
	if u.Total.Spend != u.ByModel[0].Spend+u.ByModel[1].Spend {
		t.Fatalf("the parts add up: %+v", u)
	}
	// The same requests belong to different evenings in different timezones.
	west, _ := f.s.Usage(f.ctx, f.me, 7, 14*60) // UTC-14: 12:00Z is 22:00 the day before
	if west.Days[4].Requests != 3 || west.Days[5].Requests != 0 || west.Days[6].Requests != 1 {
		t.Fatalf("west: %+v", west.Days)
	}
	f.now = f.now.Add(LogRetention + time.Hour)
	f.s.Prune(f.ctx)
	if logs, _ := f.s.Logs(f.ctx, f.me, LogFilter{}, 10); len(logs) != 0 {
		t.Fatalf("old requests are pruned: %d", len(logs))
	}
}

func TestPlaygroundRunsThroughTheSameEngine(t *testing.T) {
	f := harness(t)
	sc := f.personal(t)
	temp := 0.2
	out := f.s.Playground(f.ctx, sc, PlaygroundRequest{Type: "language", Model: "gemini-3.8-flash", Messages: []chatMessage{{Role: "user", Content: "hi"}}, Temperature: &temp, MaxTokens: 64, Route: ConsoleRoute{Order: []string{"openrouter"}}})
	if out.Status != 200 || out.Text != "hello" || out.Provider != "openrouter" || out.Cost == 0 || out.LogID == "" {
		t.Fatalf("%+v", out)
	}
	if f.http.bodies[0]["temperature"] != 0.2 || f.http.bodies[0]["max_tokens"] != float64(64) {
		t.Fatalf("settings reach the provider: %v", f.http.bodies[0])
	}
	logs, _ := f.s.Logs(f.ctx, f.me, LogFilter{KeyID: "playground"}, 5)
	if len(logs) != 1 || logs[0].KeyName != "Playground" {
		t.Fatalf("%+v", logs)
	}
	f.fin.balance[f.me] = 0
	if bad := f.s.Playground(f.ctx, sc, PlaygroundRequest{Model: "gpt-5-mini", Messages: []chatMessage{{Role: "user", Content: "hi"}}}); bad.Status != 402 || bad.Error == "" {
		t.Fatalf("%+v", bad)
	}
}

// TestTheRealRouterServesTheAPIOnTheDeveloperHost wires the namespace's routes
// to the node's own HTTP adapter and calls them over a socket, as a developer would.
func TestTheRealRouterServesTheAPIOnTheDeveloperHost(t *testing.T) {
	f := harness(t)
	_, secret := f.key(t, f.personal(t), KeyInput{Name: "web", Permissions: all})
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
	do := func(method, path, body string) (*http.Response, string) {
		req, _ := http.NewRequest(method, "http://"+addr+path, strings.NewReader(body))
		req.Host = "api.test"
		req.Header.Set("Authorization", "Bearer "+secret)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		raw, _ := io.ReadAll(resp.Body)
		return resp, string(raw)
	}
	if r, body := do("GET", "/v1/models", ""); r.StatusCode != 200 || !strings.Contains(body, "google/gemini-3.8-flash") {
		t.Fatalf("models: %d %s", r.StatusCode, body)
	}
	if r, body := do("GET", "/v1/models/google/gemini-3.8-flash", ""); r.StatusCode != 200 || !strings.Contains(body, `"pricing"`) {
		t.Fatalf("one model: %d %s", r.StatusCode, body)
	}
	// Every kind of model has its route on the developer host (a request without a model is a 400, not a 404).
	for _, path := range []string{"/v1/images/generations", "/v1/videos/generations", "/v1/audio/speech", "/v1/audio/transcriptions", "/v1/rerank", "/v1/decisions", "/v1/embeddings"} {
		if r, body := do("POST", path, `{}`); r.StatusCode != 400 {
			t.Fatalf("%s: %d %s", path, r.StatusCode, body)
		}
	}
	if r, body := do("GET", "/v1/videos/vid_nothing", ""); r.StatusCode != 404 || !strings.Contains(body, "No video") {
		t.Fatalf("video status: %d %s", r.StatusCode, body)
	}
	r, body := do("POST", "/v1/chat/completions", `{"model":"gemini-3.8-flash","stream":true,"messages":[{"role":"user","content":"hi"}]}`)
	if r.StatusCode != 200 || r.Header.Get("X-Tradera-Model") != "google/gemini-3.8-flash" || r.Header.Get("X-Tradera-Provider") != "" {
		t.Fatalf("stream: %d %v %s", r.StatusCode, r.Header, body)
	}
	if r2, _ := do("POST", "/v1/chat/completions", `{"model":"gemini-3.8-flash","messages":[{"role":"user","content":"hi"}]}`); r2.StatusCode != 200 || r2.Header.Get("X-RateLimit-Limit") == "" {
		t.Fatalf("chat: %d %v", r2.StatusCode, r2.Header)
	}
	if r3, _ := do("GET", "/v1/auth/whoami", ""); r3.StatusCode != 404 {
		t.Fatalf("the developer host serves only the developer API: %d", r3.StatusCode)
	}
}

func TestCatalogUsesWhatTheSourceReports(t *testing.T) {
	owner, _ := identity.New(1)
	guessed := offering("openai", "openai", "gpt-5-mini", true, 1, 1, owner)
	imported := offering("vercel", "vercel", "openai/gpt-5-mini", false, 1, 1, owner)
	imported.Label, imported.Tags, imported.Inputs = "GPT-5 mini", []string{"tool-use", "structured-output", "implicit-caching"}, []string{"text", "image", "pdf"}
	cat := BuildCatalog([]dto.Offering{guessed, imported})
	m := FindModel(cat, "openai/gpt-5-mini")
	if m == nil || len(m.Endpoints) != 2 {
		t.Fatalf("one entry for both providers: %+v", cat)
	}
	// The guess from the name says reasoning; Vercel's tags do not, and say caching.
	if contains(m.Capabilities, "reasoning") || !contains(m.Capabilities, "caching") || !contains(m.Capabilities, "tools") || !contains(m.Modalities.Input, "file") {
		t.Fatalf("the source's tags beat the guess: %+v", m)
	}
}

func TestTheAdminSeesEveryOrganization(t *testing.T) {
	f := harness(t)
	f.s.Infra = fakeInfra{}
	// A person using their personal organization, and a team with two people and a key of its own.
	p, _ := f.key(t, f.personal(t), KeyInput{Name: "app", Permissions: all})
	f.s.Execute(f.ctx, chatCall(p, "google/gemini-3.8-flash"))
	failing := chatCall(p, "nothing/here")
	f.s.Execute(f.ctx, failing)
	team, err := f.s.CreateOrg(f.ctx, f.me, "Acme")
	if err != nil {
		t.Fatal(err)
	}
	teamScope, _ := f.s.Scope(f.ctx, f.me, team.ID)
	f.fin.balance[teamScope.Org] = 7_000_000
	tk, _ := f.key(t, teamScope, KeyInput{Name: "acme-prod", Permissions: all})
	f.s.Execute(f.ctx, chatCall(tk, "gpt-5-mini"))
	f.s.Execute(f.ctx, chatCall(tk, "gpt-5-mini"))

	o, err := f.s.AdminOrgs(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if o.Totals.Orgs != 2 || o.Totals.Active != 2 || o.Totals.Requests != 4 || o.Totals.Errors != 1 || o.Totals.Keys != 2 {
		t.Fatalf("totals: %+v", o.Totals)
	}
	byName := map[string]AdminOrgRow{}
	for _, r := range o.Orgs {
		byName[r.Name] = r
	}
	acme, mine := byName["Acme"], byName["@ada"]
	if acme.Kind != "team" || acme.Owner != "ada" || acme.Members != 1 || acme.Keys != 1 || acme.Requests != 2 || acme.Balance != 7_000_000-acme.Spend {
		t.Fatalf("the team: %+v", acme)
	}
	if mine.Kind != "personal" || mine.Requests != 2 || mine.Errors != 1 || mine.Spend != 900 || mine.LastAt == "" {
		t.Fatalf("the personal organization: %+v", mine)
	}
	if o.Orgs[0].Spend < o.Orgs[1].Spend {
		t.Fatal("the busiest organization comes first")
	}

	d, err := f.s.AdminOrg(f.ctx, team.ID)
	if err != nil {
		t.Fatal(err)
	}
	if d.Org.Name != "Acme" || len(d.KeyList) != 1 || d.KeyList[0].Name != "acme-prod" || len(d.Members) != 1 || d.Usage.Total.Requests != 2 || len(d.Logs) != 2 || d.Logs[0].Provider != "openai" || d.Storage == nil {
		t.Fatalf("the team in full: %+v", d)
	}
	if only, _ := f.s.AdminLogs(f.ctx, f.me.String(), LogFilter{Status: "error"}, 10); len(only) != 1 || only[0].OrgName != "@ada" {
		t.Fatalf("one organization's failed requests: %+v", only)
	}
	if _, err := f.s.AdminOrg(f.ctx, "nope"); err == nil {
		t.Fatal("an unknown organization is not found")
	}
}

type leaving struct{ cancel context.CancelFunc }

// Do is a provider call during which the caller hangs up.
func (d leaving) Do(r *http.Request) (*http.Response, error) {
	d.cancel()
	return nil, context.Canceled
}

func TestACallerWhoLeavesStillPaysTheInput(t *testing.T) {
	f := harness(t)
	p, _ := f.key(t, f.personal(t), KeyInput{Name: "app", Permissions: all})
	ctx, cancel := context.WithCancel(f.ctx)
	f.s.HTTP = leaving{cancel}
	call := chatCall(p, "google/gemini-3.8-flash")
	call.Body["messages"] = []any{map[string]any{"role": "user", "content": strings.Repeat("word ", 4000)}}
	res := f.s.Execute(ctx, call)
	if res.Status != 499 || errCode(res) != "client_closed" {
		t.Fatalf("%d %s", res.Status, res.Body)
	}
	in := estimateTokens(call.Body)
	if in < 5000 || f.fin.billed[f.me] <= 0 {
		t.Fatalf("the provider was sent ~%d tokens, billed %v", in, f.fin.billed)
	}
	logs, _ := f.s.Logs(f.ctx, f.me, LogFilter{}, 10)
	if len(logs) != 1 || logs[0].Status != 499 || logs[0].TokensIn != in || logs[0].Cost != f.fin.billed[f.me] {
		t.Fatalf("logs: %+v", logs)
	}
}
