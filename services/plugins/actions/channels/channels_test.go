package channels

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
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
	cm "github.com/aseman/aseman/plugins/actions/channels/models"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

const personHex = "00000000000000010000000000000001"

type fakeSpaces struct {
	mu        sync.Mutex
	tasks     []string
	initiator string
}

func (f *fakeSpaces) HomeSpace(context.Context, identity.ID) (*space.Space, error) {
	id, _ := identity.Parse("00000000000000010000000000000050")
	return &space.Space{Entity: entity.Entity{ID: id}}, nil
}
func (f *fakeSpaces) RunScheduledTask(ctx context.Context, _, _, _ identity.ID, task string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.tasks = append(f.tasks, task)
	f.initiator = vmm.InitiatorFrom(ctx).Kind
	return "Sent the quote.\n<replies>Thanks | Show me</replies>", nil
}

type fakeGovernance struct{ answers []string }

func (f *fakeGovernance) Answer(_ context.Context, caller identity.ID, id, answer string) error {
	f.answers = append(f.answers, caller.String()+"/"+id+"/"+answer)
	return nil
}

// recorder stands in for Slack's, Twilio's and the Bot Connector's APIs.
type recorder struct {
	mu    sync.Mutex
	calls []string
}

func (r *recorder) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	body, _ := io.ReadAll(req.Body)
	r.mu.Lock()
	r.calls = append(r.calls, req.URL.Path+" "+string(body))
	r.mu.Unlock()
	if strings.HasSuffix(req.URL.Path, "/token") {
		_ = json.NewEncoder(w).Encode(map[string]any{"access_token": "app-token", "expires_in": 3600})
		return
	}
	_, _ = w.Write([]byte(`{"ok":true}`))
}

func harness(t *testing.T) (*Service, *fakeSpaces, *fakeGovernance, *recorder, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range append(dbmodel.Models(), cm.Models()...) {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{"node_private_key": strings.Repeat("12", 64)}})
	s := NewService(k, &repo.Repo{DB: db}, logger.Global())
	spaces, gov, rec := &fakeSpaces{}, &fakeGovernance{}, &recorder{}
	api := httptest.NewServer(rec)
	t.Cleanup(api.Close)
	s.Spaces, s.Governance, s.SlackAPI, s.TwilioAPI, s.BotFrameworkToken = spaces, gov, api.URL+"/slack", api.URL+"/twilio", api.URL+"/token"
	s.run = func(f func()) { f() }
	person, _ := identity.Parse(personHex)
	if err := db.Create(ctx, "accounts", personHex, &account.Account{Entity: entity.Entity{ID: person}, Kind: account.KindUser, Handle: "sam", Status: account.StatusActive}); err != nil {
		t.Fatal(err)
	}
	return s, spaces, gov, rec, ctx
}

func slackSigned(secret string, body []byte) map[string]string {
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte("v0:" + ts + ":"))
	mac.Write(body)
	return map[string]string{"X-Slack-Request-Timestamp": ts, "X-Slack-Signature": "v0=" + hex.EncodeToString(mac.Sum(nil))}
}

func TestSlackLinkConverseAndApprove(t *testing.T) {
	s, spaces, gov, rec, ctx := harness(t)
	person, _ := identity.Parse(personHex)
	if _, err := s.SaveSettings(ctx, person, cm.Settings{Provider: cm.Slack, Enabled: true}, "signing", "xoxb-bot"); err != nil {
		t.Fatal(err)
	}
	code, err := s.LinkCode(ctx, person, cm.Slack)
	if err != nil {
		t.Fatal(err)
	}
	event := func(text string) []byte {
		raw, _ := json.Marshal(map[string]any{"type": "event_callback", "team_id": "T1",
			"event": map[string]any{"type": "message", "channel_type": "im", "channel": "D1", "user": "U1", "text": text, "ts": "1.1"}})
		return raw
	}
	unsigned := event("hello")
	if resp, _ := s.serveSlackEvents(ctx, &network.Request{Header: map[string]string{"X-Slack-Signature": "v0=bad", "X-Slack-Request-Timestamp": strconv.FormatInt(time.Now().Unix(), 10)}, Body: unsigned}); resp.Status != http.StatusUnauthorized {
		t.Fatal("an unsigned delivery is refused")
	}
	body := event("hello")
	_, _ = s.serveSlackEvents(ctx, &network.Request{Header: slackSigned("signing", body), Body: body})
	if len(spaces.tasks) != 0 || !strings.Contains(rec.calls[0], "link") {
		t.Fatal("an unlinked person is told how to link, and nothing runs")
	}
	body = event("link " + code)
	_, _ = s.serveSlackEvents(ctx, &network.Request{Header: slackSigned("signing", body), Body: body})
	if b, ok := s.binding(ctx, cm.Slack, "T1", "U1"); !ok || b.AccountID != personHex {
		t.Fatal("the code links the Slack user to the account")
	}
	body = event("send Priya the quote")
	_, _ = s.serveSlackEvents(ctx, &network.Request{Header: slackSigned("signing", body), Body: body})
	if len(spaces.tasks) != 1 || spaces.initiator != vmm.InitiatorChannel {
		t.Fatalf("the message runs as a channel turn: %v %s", spaces.tasks, spaces.initiator)
	}
	last := rec.calls[len(rec.calls)-1]
	if !strings.Contains(last, `"action_id":"reply:0"`) || strings.Contains(last, "<replies>") {
		t.Fatalf("reply chips become buttons: %s", last)
	}
	// An approval is offered, and answered, in Slack.
	if err := s.ApprovalAsked(ctx, gate.ApprovalNote{ID: "00000000000000010000000000000077", ActorID: personHex, Summary: "aseman wants to send a message"}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(rec.calls[len(rec.calls)-1], "approval:always") {
		t.Fatal("the approval has its three buttons")
	}
	payload, _ := json.Marshal(map[string]any{"user": map[string]string{"id": "U1"}, "team": map[string]string{"id": "T1"},
		"channel": map[string]string{"id": "D1"}, "message": map[string]string{"ts": "2.2"},
		"actions": []map[string]string{{"action_id": "approval:once", "value": "00000000000000010000000000000077"}}})
	form := []byte(url.Values{"payload": {string(payload)}}.Encode())
	_, _ = s.serveSlackActions(ctx, &network.Request{Header: slackSigned("signing", form), Body: form})
	if len(gov.answers) != 1 || gov.answers[0] != personHex+"/00000000000000010000000000000077/once" {
		t.Fatalf("answered as the linked person: %v", gov.answers)
	}
}

func TestSMSApprovalByCode(t *testing.T) {
	s, _, gov, rec, ctx := harness(t)
	person, _ := identity.Parse(personHex)
	if _, err := s.SaveSettings(ctx, person, cm.Settings{Provider: cm.Twilio, Enabled: true, AppID: "AC1", From: "+15550001"}, "", "twilio-token"); err != nil {
		t.Fatal(err)
	}
	code, _ := s.LinkCode(ctx, person, cm.Twilio)
	sms := func(text string) *network.Response {
		form := url.Values{"From": {"+15550100"}, "To": {"+15550001"}, "Body": {text}}
		resp, _ := s.serveSMS(ctx, &network.Request{Header: map[string]string{"X-Twilio-Signature": twilioSignature("twilio-token", twilioURL(), form)}, Body: []byte(form.Encode())})
		return resp
	}
	if resp := sms("link " + code); !strings.Contains(string(resp.Body), "Linked") {
		t.Fatalf("%s", resp.Body)
	}
	if err := s.ApprovalAsked(ctx, gate.ApprovalNote{ID: "00000000000000010000000000000078", ActorID: personHex, Summary: "pay the invoice"}); err != nil {
		t.Fatal(err)
	}
	var prompts []cm.SMSPrompt
	_ = s.R.List(ctx, "channel_sms_prompts", databaseAll(), &prompts)
	if len(prompts) != 1 || !strings.Contains(rec.calls[len(rec.calls)-1], "YES+"+prompts[0].Code) {
		t.Fatalf("the text names the code: %v", rec.calls)
	}
	if resp := sms("NO " + prompts[0].Code); !strings.Contains(string(resp.Body), "Refused") || gov.answers[0] != personHex+"/00000000000000010000000000000078/refuse" {
		t.Fatalf("%s %v", resp.Body, gov.answers)
	}
}

func TestTeamsTokenIsVerified(t *testing.T) {
	s, spaces, _, _, ctx := harness(t)
	key, _ := rsa.GenerateKey(rand.Reader, 2048)
	keys := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/openid" {
			_ = json.NewEncoder(w).Encode(map[string]string{"jwks_uri": "http://" + r.Host + "/keys"})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{"kty": "RSA", "kid": "k1",
			"n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()), "e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes())}}})
	}))
	defer keys.Close()
	s.BotFrameworkOpenID = keys.URL + "/openid"
	person, _ := identity.Parse(personHex)
	if _, err := s.SaveSettings(ctx, person, cm.Settings{Provider: cm.Teams, Enabled: true, AppID: "app-1"}, "app-password", ""); err != nil {
		t.Fatal(err)
	}
	sign := func(aud string) string {
		tok := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{"iss": botFrameworkIssuer, "aud": aud, "exp": time.Now().Add(time.Hour).Unix()})
		tok.Header["kid"] = "k1"
		raw, _ := tok.SignedString(key)
		return "Bearer " + raw
	}
	body, _ := json.Marshal(map[string]any{"type": "message", "id": "a1", "text": "hello", "serviceUrl": "http://unused",
		"from": map[string]string{"aadObjectId": "aad-1"}, "conversation": map[string]string{"id": "c1", "tenantId": "t1"}})
	if resp, _ := s.serveTeams(ctx, &network.Request{Header: map[string]string{"Authorization": sign("another-app")}, Body: body}); resp.Status != http.StatusUnauthorized {
		t.Fatal("a token for another app is refused")
	}
	if resp, _ := s.serveTeams(ctx, &network.Request{Header: map[string]string{"Authorization": sign("app-1")}, Body: body}); resp.Status != http.StatusOK || len(spaces.tasks) != 0 {
		t.Fatal("a verified message from an unlinked person runs nothing")
	}
}

func databaseAll() database.Filter { return database.Filter{} }
