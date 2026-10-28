package google

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/fakegoogle"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	gm "github.com/aseman/aseman/plugins/actions/google/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

const personHex = "00000000000000010000000000000001"

func harness(t *testing.T) (*Service, *fakegoogle.Server, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range append(dbmodel.Models(), gm.Models()...) {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"node_private_key": strings.Repeat("cd", 64)}})
	s := NewService(k, &repo.Repo{DB: db}, logger.Global())
	fake := fakegoogle.New()
	srv := httptest.NewServer(fake)
	t.Cleanup(srv.Close)
	s.ep = &endpoints{Auth: srv.URL + "/o/oauth2/v2/auth", Token: srv.URL + "/token", Gmail: srv.URL + "/gmail/v1",
		Calendar: srv.URL + "/calendar/v3", UserInfo: srv.URL + "/oauth2/v3/userinfo", Fake: true}
	person, _ := identity.Parse(personHex)
	if err := db.Create(ctx, "accounts", personHex, &account.Account{Entity: entity.Entity{ID: person}, Kind: account.KindUser, Handle: "sam", Status: account.StatusActive}); err != nil {
		t.Fatal(err)
	}
	return s, fake, ctx
}

func connect(t *testing.T, s *Service, ctx context.Context) {
	t.Helper()
	person, _ := identity.Parse(personHex)
	if _, _, err := s.settings(ctx); err != nil {
		if _, err := s.StartConnect(ctx, person, "/connections"); err == nil {
			t.Fatal("connecting before the administrator set up Google must fail")
		}
		if _, err := s.SaveSettings(ctx, person, true, "client-id", "client-secret"); err != nil {
			t.Fatal(err)
		}
	}
	raw, err := s.StartConnect(ctx, person, "/connections")
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(raw)
	if u.Query().Get("code_challenge_method") != "S256" || u.Query().Get("access_type") != "offline" {
		t.Fatalf("consent must use PKCE and offline access: %s", raw)
	}
	c, ret, err := s.FinishConnect(ctx, u.Query().Get("state"), "fake-code")
	if err != nil || ret != "/connections" || c.Email != fakegoogle.Owner {
		t.Fatalf("%+v %q %v", c, ret, err)
	}
	if _, _, err := s.FinishConnect(ctx, u.Query().Get("state"), "fake-code"); err == nil {
		t.Fatal("a state is used once")
	}
}

// mcpCall is one JSON-RPC call to the Google app's MCP server.
func mcpCall(t *testing.T, s *Service, ctx context.Context, key, actor, method string, params any) map[string]any {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	resp, err := s.serveMCP(ctx, &network.Request{Header: map[string]string{"x-aseman-app-key": key, "x-aseman-actor": actor}, Body: body})
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]any{"status": resp.Status}
	_ = json.Unmarshal(resp.Body, &out)
	return out
}

func callText(out map[string]any) (string, bool) {
	result, _ := out["result"].(map[string]any)
	content, _ := result["content"].([]any)
	if len(content) == 0 {
		return "", false
	}
	first, _ := content[0].(map[string]any)
	text, _ := first["text"].(string)
	isErr, _ := result["isError"].(bool)
	return text, !isErr
}

func TestGoogleIsAnApp(t *testing.T) {
	s, fake, ctx := harness(t)
	var listed map[string]any
	s.Register = func(_ context.Context, _ identity.ID, body map[string]any) (string, error) {
		listed = body
		return "00000000000000010000000000000077", nil
	}
	s.listedCheck = func(string) bool { return listed != nil }
	person, _ := identity.Parse(personHex)
	if _, err := s.SaveSettings(ctx, person, true, "client-id", "client-secret"); err != nil {
		t.Fatal(err)
	}
	bot, err := s.EnsureApp(ctx, person)
	if err != nil || bot == "" || listed["name"] != AppName || listed["listed"] != true {
		t.Fatalf("listed in the catalog: %v %v %+v", bot, err, listed)
	}
	headers, _ := listed["headers"].(map[string]string)
	if headers["X-Aseman-Actor"] != "{{actor}}" || len(headers["X-Aseman-App-Key"]) != 64 || !strings.HasSuffix(listed["url"].(string), MCPPath) {
		t.Fatalf("the app calls this node with its key and the person: %+v", listed)
	}
	if again, _ := s.EnsureApp(ctx, person); again != bot {
		t.Fatal("listed once")
	}
	key := headers["X-Aseman-App-Key"]
	if out := mcpCall(t, s, ctx, "wrong", personHex, "tools/list", nil); out["status"] != 401 {
		t.Fatalf("a call without the app's key is refused: %+v", out)
	}
	tools := mcpCall(t, s, ctx, key, personHex, "tools/list", nil)["result"].(map[string]any)["tools"].([]any)
	if len(tools) != len(appTools) {
		t.Fatalf("%d tools", len(tools))
	}
	if text, ok := callText(mcpCall(t, s, ctx, key, personHex, "tools/call", map[string]any{"name": "gmail_read", "arguments": map[string]any{"id": "m06"}})); ok || !strings.Contains(text, "Apps → Google") {
		t.Fatalf("not connected yet: %q", text)
	}
	connect(t, s, ctx)
	text, ok := callText(mcpCall(t, s, ctx, key, personHex, "tools/call", map[string]any{"name": "gmail_read", "arguments": map[string]any{"id": "m06"}}))
	if !ok || !strings.Contains(text, `<untrusted_data source="email from Marco`) {
		t.Fatalf("mail reaches the agent in the envelope: %q", text)
	}
	if _, ok := callText(mcpCall(t, s, ctx, key, personHex, "tools/call", map[string]any{"name": "gmail_send",
		"arguments": map[string]any{"to": "marco@bellini.example", "body": "Ready Tuesday.", "reply_to": "m06"}})); !ok {
		t.Fatal("send")
	}
	sent, _, _ := fake.Sent()
	if len(sent) != 1 || sent[0]["threadId"] != "tm06" {
		t.Fatalf("the reply goes into the thread: %+v", sent)
	}
	if _, ok := callText(mcpCall(t, s, ctx, key, "00000000000000010000000000000009", "tools/call", map[string]any{"name": "gmail_read", "arguments": map[string]any{"id": "m06"}})); ok {
		t.Fatal("someone else's call uses their own connection, not this person's")
	}
}

func TestConnectReadAndSend(t *testing.T) {
	s, _, ctx := harness(t)
	connect(t, s, ctx)
	mails, err := s.SearchMail(ctx, personHex, "is:unread", 20)
	if err != nil || len(mails) != 4 {
		t.Fatalf("unread mail: %d %v", len(mails), err)
	}
	read, err := s.ReadMail(ctx, personHex, "m01")
	if err != nil || !strings.Contains(read.Body, "12 cargo bikes") || read.Date.IsZero() {
		t.Fatalf("%+v %v", read, err)
	}
	from, to := DayBounds(time.Now(), "UTC")
	events, err := s.Events(ctx, personHex, from, to, "")
	if err != nil || len(events) != 2 {
		t.Fatalf("today's events: %d %v", len(events), err)
	}
	if err := s.Disconnect(ctx, personHex); err != nil || s.Connected(ctx, personHex) {
		t.Fatal("disconnect")
	}
}

func TestSafeReturnStaysInTheApp(t *testing.T) {
	for in, want := range map[string]string{"/tasks": "/tasks", "https://evil.example": "/", "//evil.example": "/", "": "/"} {
		if got := safeReturn(in); got != want {
			t.Errorf("%q: %q", in, got)
		}
	}
}
