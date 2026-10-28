package google

import (
	"context"
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
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
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
	if _, err := s.StartConnect(ctx, person, "/connections"); err == nil {
		t.Fatal("connecting before the administrator set up Google must fail")
	}
	if _, err := s.SaveSettings(ctx, person, true, "client-id", "client-secret"); err != nil {
		t.Fatal(err)
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

func TestConnectReadAndSend(t *testing.T) {
	s, fake, ctx := harness(t)
	if tools, _ := s.AvailableTools(ctx, personHex, ""); len(tools) != 0 {
		t.Fatal("no tools before connecting")
	}
	connect(t, s, ctx)
	if tools, _ := s.AvailableTools(ctx, personHex, ""); len(tools) != len(agentTools) {
		t.Fatal("mail and calendar after connecting")
	}
	mails, err := s.SearchMail(ctx, personHex, "is:unread", 20)
	if err != nil || len(mails) != 4 {
		t.Fatalf("unread mail: %d %v", len(mails), err)
	}
	read, err := s.ReadMail(ctx, personHex, "m01")
	if err != nil || !strings.Contains(read.Body, "12 cargo bikes") || read.Date.IsZero() {
		t.Fatalf("%+v %v", read, err)
	}
	out, err := s.AgentTool(ctx, gate.ToolCall{Tool: "gmail_read", Args: `{"id":"m06"}`, ActorID: personHex})
	if err != nil || !strings.Contains(out, `<untrusted_data source="email from Marco`) {
		t.Fatalf("mail reaches the agent in the envelope: %q %v", out, err)
	}
	if _, err := s.AgentTool(ctx, gate.ToolCall{Tool: "gmail_send", Args: `{"to":"marco@bellini.example","body":"Ready Tuesday.","reply_to":"m06"}`, ActorID: personHex}); err != nil {
		t.Fatal(err)
	}
	sent, _, _ := fake.Sent()
	if len(sent) != 1 || sent[0]["threadId"] != "tm06" {
		t.Fatalf("the reply goes into the thread: %+v", sent)
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
	for in, want := range map[string]string{"/tasks": "/tasks", "https://evil.example": "/connections", "//evil.example": "/connections", "": "/connections"} {
		if got := safeReturn(in); got != want {
			t.Errorf("%q: %q", in, got)
		}
	}
}
