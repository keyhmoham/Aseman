package governance

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	gov "github.com/aseman/aseman/plugins/actions/governance/models"
	"github.com/aseman/aseman/plugins/actions/governance/models/egress"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

const (
	spaceHex = "00000000000000010000000000000099"
	ownerHex = "00000000000000010000000000000001"
	otherHex = "00000000000000010000000000000002"
	agentHex = "00000000000000010000000000000003"
)

type fakeSpaces struct {
	mu    sync.Mutex
	posts []string
}

func (f *fakeSpaces) PostMessage(_ context.Context, _, _, _ identity.ID, body string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.posts = append(f.posts, body)
	return nil
}
func (f *fakeSpaces) AsemanAccount(context.Context) (identity.ID, error) { return identity.Parse(agentHex) }
func (f *fakeSpaces) SandboxExec(context.Context, identity.ID, string) (string, error) {
	return "", nil
}

type fakeUsers struct{ pushes int }

func (f *fakeUsers) Push(context.Context, []identity.ID, PushNote) { f.pushes++ }

func mustID(t *testing.T, h string) identity.ID {
	t.Helper()
	id, err := identity.Parse(h)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func harness(t *testing.T) (*Service, *fakeSpaces, context.Context) {
	t.Helper()
	t.Setenv("ASEMAN_AUDIT_READS", "1")
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range append(dbmodel.Models(), gov.Models()...) {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global(), Env: map[string]string{
		"node_private_key": strings.Repeat("ab", 64), "admin_handle": "node-a"}})
	s := NewService(k, &repo.Repo{DB: db}, logger.Global())
	s.pollEvery = 10 * time.Millisecond
	s.ApprovalTimeout, s.HandoverWait = 2*time.Second, 2*time.Second
	spaces := &fakeSpaces{}
	s.Spaces, s.Users = spaces, &fakeUsers{}
	owner, other := mustID(t, ownerHex), mustID(t, otherHex)
	for _, rec := range []struct {
		model string
		id    identity.ID
		v     any
	}{
		{"accounts", owner, &account.Account{Entity: entity.Entity{ID: owner}, Kind: account.KindUser, Handle: "maya", Status: account.StatusActive}},
		{"accounts", other, &account.Account{Entity: entity.Entity{ID: other}, Kind: account.KindUser, Handle: "sam", Status: account.StatusActive}},
		{"memberships", mustID(t, "00000000000000010000000000000010"), &membership.Membership{Entity: entity.Entity{ID: mustID(t, "00000000000000010000000000000010")},
			SpaceID: mustID(t, spaceHex), MemberID: owner, Role: membership.RoleOwner}},
	} {
		if err := db.Create(ctx, rec.model, rec.id.String(), rec.v); err != nil {
			t.Fatal(err)
		}
	}
	return s, spaces, ctx
}

func req(kind, tool string, args any) gate.Request {
	raw, _ := json.Marshal(args)
	return gate.Request{Kind: kind, Tool: tool, Args: raw, SpaceID: spaceHex, ActorID: ownerHex, AgentID: agentHex, AgentName: "aseman"}
}

func TestCommandEffects(t *testing.T) {
	for cmd, want := range map[string]string{
		"ls -la /workspace":                         gate.EffectRead,
		"cat a.txt | grep foo | wc -l":              gate.EffectRead,
		"git status && git log --oneline":           gate.EffectRead,
		"ls 2>/dev/null":                            gate.EffectRead,
		"npm install":                               gate.EffectWrite,
		"echo hi > out.txt":                         gate.EffectWrite,
		"rm -rf /workspace":                         gate.EffectDelete,
		"rm -rf build":                              gate.EffectWrite,
		"psql -c 'DROP TABLE users'":                gate.EffectDelete,
		"curl -X POST https://api.example.com/x":    gate.EffectExternal,
		"curl -d a=b http://localhost:3000/hook":    gate.EffectWrite,
		"git push origin main":                      gate.EffectExternal,
		"echo body | sendmail someone@example.com": gate.EffectSend,
		"find . -name '*.tmp' -delete":              gate.EffectWrite,
	} {
		if got := commandEffect(cmd); got != want {
			t.Errorf("%q: got %s want %s", cmd, got, want)
		}
	}
}

func TestEffectFromName(t *testing.T) {
	for name, want := range map[string]string{
		"list_orders": gate.EffectRead, "sendEmail": gate.EffectSend, "refund_payment": gate.EffectPay,
		"delete_file": gate.EffectDelete, "createDraft": gate.EffectWrite, "sign_contract": gate.EffectSign,
	} {
		if got := effectFromName(name); got != want {
			t.Errorf("%s: got %s want %s", name, got, want)
		}
	}
}

func TestCompileRejectsBadRules(t *testing.T) {
	if _, err := Compile(gov.Policy{Deny: []string{"tool.name =="}}); err == nil {
		t.Fatal("a rule that does not parse must be refused")
	}
	if _, err := Compile(gov.Policy{Allow: []string{`"text"`}}); err == nil {
		t.Fatal("a rule that is not boolean must be refused")
	}
	if _, err := Compile(DefaultPolicy()); err != nil {
		t.Fatal(err)
	}
}

func TestGateAllowsReadsAndDeniesMetadata(t *testing.T) {
	s, _, ctx := harness(t)
	res, err := s.Gate(ctx, req(gate.KindSandbox, "sandbox_exec", map[string]any{"command": "ls"}))
	if err != nil || !res.Allowed {
		t.Fatalf("a read must run: %+v %v", res, err)
	}
	res, _ = s.Gate(ctx, req(gate.KindSandbox, "sandbox_exec", map[string]any{"command": "curl http://169.254.169.254/latest/meta-data"}))
	if res.Allowed || !strings.Contains(res.Reason, "policy") {
		t.Fatalf("cloud metadata must be refused: %+v", res)
	}
	rows, _, err := s.Audit(ctx, mustID(t, ownerHex), AuditQuery{Space: spaceHex})
	if err != nil || len(rows) != 2 {
		t.Fatalf("both decisions must be recorded: %d %v", len(rows), err)
	}
}

func answerWhenAsked(t *testing.T, s *Service, ctx context.Context, answer string) {
	t.Helper()
	go func() {
		for i := 0; i < 200; i++ {
			var rows []gov.Approval
			_ = s.R.List(ctx, "approvals", database.Filter{Equal: map[string]any{"status": gov.ApprovalPending}}, &rows)
			if len(rows) > 0 {
				if _, err := s.AnswerApproval(ctx, mustID(t, ownerHex), rows[0].ID, answer); err != nil {
					t.Error(err)
				}
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
	}()
}

func TestAskOnceAlwaysAndRefuse(t *testing.T) {
	s, spaces, ctx := harness(t)
	send := req(gate.KindTool, "gmail_send", map[string]any{"to": "jamie@example.com", "body": "The order shipped."})

	answerWhenAsked(t, s, ctx, gov.AnswerRefuse)
	res, _ := s.Gate(ctx, send)
	if res.Allowed || res.Decision != gov.DecisionRefused {
		t.Fatalf("a refused approval must refuse: %+v", res)
	}
	if len(spaces.posts) == 0 || !strings.Contains(spaces.posts[0], `"c":"Approval"`) {
		t.Fatalf("the approval card must be posted: %v", spaces.posts)
	}

	answerWhenAsked(t, s, ctx, gov.AnswerOnce)
	if res, _ = s.Gate(ctx, send); !res.Allowed || res.Decision != gov.DecisionApproved {
		t.Fatalf("allow once must allow: %+v", res)
	}

	answerWhenAsked(t, s, ctx, gov.AnswerAlways)
	if res, _ = s.Gate(ctx, send); !res.Allowed {
		t.Fatalf("always must allow: %+v", res)
	}
	// The grant lets the same action through without asking again.
	if res, _ = s.Gate(ctx, send); !res.Allowed || res.Decision != gov.DecisionAllowed || !strings.HasPrefix(res.Rule, "always allowed") {
		t.Fatalf("a standing grant must allow without asking: %+v", res)
	}
	// A different recipient still asks.
	other := req(gate.KindTool, "gmail_send", map[string]any{"to": "someone@else.com", "body": "hi"})
	s.ApprovalTimeout = 50 * time.Millisecond
	if res, _ = s.Gate(ctx, other); res.Allowed || res.Decision != gov.DecisionTimedOut {
		t.Fatalf("an unanswered approval must time out as a refusal: %+v", res)
	}
}

func TestProactiveRunsOnlyRead(t *testing.T) {
	s, _, ctx := harness(t)
	ctx = vmm.WithInitiator(ctx, vmm.Initiator{Kind: vmm.InitiatorProactive})
	if res, _ := s.Gate(ctx, req(gate.KindTool, "gmail_search", map[string]any{"query": "is:unread"})); !res.Allowed {
		t.Fatalf("background research may read: %+v", res)
	}
	if res, _ := s.Gate(ctx, req(gate.KindTool, "gmail_draft", map[string]any{"to": "a@b.c"})); res.Allowed {
		t.Fatalf("background research must not write: %+v", res)
	}
	rows, _, _ := s.Audit(ctx, mustID(t, ownerHex), AuditQuery{Space: spaceHex, Unattended: true})
	if len(rows) != 2 {
		t.Fatalf("nobody-watching filter must find the unattended rows: %d", len(rows))
	}
}

func TestProjectPolicyNarrowsNode(t *testing.T) {
	s, _, ctx := harness(t)
	if _, err := s.SavePolicy(ctx, gov.Policy{Scope: spaceHex, Deny: []string{`tool.kind == "sandbox" && command.contains("npm publish")`}}, ownerHex); err != nil {
		t.Fatal(err)
	}
	if res, _ := s.Gate(ctx, req(gate.KindSandbox, "sandbox_exec", map[string]any{"command": "npm publish"})); res.Allowed {
		t.Fatal("the project's deny rule must refuse")
	}
	if res, _ := s.Gate(ctx, req(gate.KindSandbox, "sandbox_exec", map[string]any{"command": "npm test"})); !res.Allowed {
		t.Fatal("other commands still run")
	}
	if _, err := s.SavePolicy(ctx, gov.Policy{Scope: spaceHex, Allow: []string{`tool.effect == "read"`}}, ownerHex); err != nil {
		t.Fatal(err)
	}
	if res, _ := s.Gate(ctx, req(gate.KindSandbox, "sandbox_exec", map[string]any{"command": "npm test"})); res.Allowed {
		t.Fatal("a project allow list must be satisfied too")
	}
}

func TestSecretsArePutInAndRedacted(t *testing.T) {
	s, _, ctx := harness(t)
	if _, err := s.StoreSecret(ctx, mustID(t, ownerHex), spaceHex, "site_password", "example.com", "hunter2's!"); err != nil {
		t.Fatal(err)
	}
	res, err := s.Gate(ctx, req(gate.KindSandbox, "sandbox_exec", map[string]any{"command": "login --password {{secret:site_password}}"}))
	if err != nil || !res.Allowed {
		t.Fatalf("%+v %v", res, err)
	}
	if res.Command != `login --password 'hunter2'\''s!'` {
		t.Fatalf("the command must carry the quoted value: %q", res.Command)
	}
	if out := gate.Redact("logged in with hunter2's!", res.Secrets); out != "logged in with [secret:site_password]" {
		t.Fatalf("output must be redacted: %q", out)
	}
	rows, _, _ := s.Audit(ctx, mustID(t, ownerHex), AuditQuery{Space: spaceHex, Decision: gov.DecisionAllowed})
	for _, r := range rows {
		if strings.Contains(r.Args, "hunter2") || strings.Contains(r.Detail, "hunter2") {
			t.Fatal("the trail must never hold a secret's value")
		}
	}
	if _, err := s.Gate(ctx, req(gate.KindSandbox, "sandbox_exec", map[string]any{"command": "echo {{secret:missing}}"})); err != nil {
		t.Fatal(err)
	}
	listed, _ := s.Secrets(ctx, mustID(t, ownerHex), spaceHex)
	if len(listed) != 1 || listed[0].Sealed != "" || listed[0].Length != 10 {
		t.Fatalf("listing shows names and lengths only: %+v", listed)
	}
}

func TestSecretBoxRoundTrip(t *testing.T) {
	s, spaces, ctx := harness(t)
	done := make(chan string, 1)
	go func() {
		out, err := s.SecretRequestTool(ctx, gate.ToolCall{Tool: "secret_request", Args: `{"name":"bank_pin","reason":"to log in"}`,
			SpaceID: spaceHex, ActorID: ownerHex, AgentName: "aseman"})
		if err != nil {
			t.Error(err)
		}
		done <- out
	}()
	var reqs []gov.SecretRequest
	for i := 0; i < 200 && len(reqs) == 0; i++ {
		time.Sleep(5 * time.Millisecond)
		_ = s.R.List(ctx, "secret_requests", database.Filter{}, &reqs)
	}
	if len(reqs) == 0 {
		t.Fatal("no request")
	}
	if err := s.AnswerSecret(ctx, mustID(t, ownerHex), reqs[0].ID, "4242", false); err != nil {
		t.Fatal(err)
	}
	out := <-done
	if !strings.Contains(out, "{{secret:bank_pin}}") || strings.Contains(out, "4242") {
		t.Fatalf("the agent learns the name, never the value: %q", out)
	}
	if !strings.Contains(spaces.posts[0], `"c":"Secret"`) || strings.Contains(strings.Join(spaces.posts, ""), "4242") {
		t.Fatal("the card is a masked box and the value never reaches the room")
	}
}

func TestOutboundChecks(t *testing.T) {
	s, _, ctx := harness(t)
	leak := req(gate.KindTool, "gmail_send", map[string]any{"to": "x@y.z", "body": "token ghp_" + strings.Repeat("a", 36)})
	res, _ := s.Gate(ctx, leak)
	if res.Allowed || !strings.Contains(res.Reason, "GitHub token in args.body") || strings.Contains(res.Reason, "ghp_") {
		t.Fatalf("a credential must not leave, and the reason must not quote it: %+v", res)
	}
	if got := Findings("card 4111 1111 1111 1111 exp 12/29"); len(got) != 1 || got[0] != "payment card number" {
		t.Fatalf("Luhn-valid card: %v", got)
	}
	if got := Findings("order 1234567890123 and phone 4155550100"); len(got) != 0 {
		t.Fatalf("ordinary numbers are not cards: %v", got)
	}
	if got := Findings("use {{secret:token}} here"); len(got) != 0 {
		t.Fatalf("a secret placeholder passes: %v", got)
	}
}

func TestExportNeutralizesFormulas(t *testing.T) {
	s, _, ctx := harness(t)
	r := req(gate.KindSandbox, "sandbox_exec", map[string]any{"command": "ls"})
	r.AgentName = "=HYPERLINK(\"http://evil\")"
	if _, err := s.Gate(ctx, r); err != nil {
		t.Fatal(err)
	}
	text, n, truncated, err := s.Export(ctx, mustID(t, ownerHex), AuditQuery{Space: spaceHex})
	if err != nil || n != 1 || truncated {
		t.Fatalf("%d %v %v", n, truncated, err)
	}
	if !strings.Contains(text, `'=HYPERLINK`) {
		t.Fatalf("formula must be neutralized: %s", text)
	}
	rows, _, _ := s.Audit(ctx, mustID(t, ownerHex), AuditQuery{Space: spaceHex, Event: "audit.exported"})
	if len(rows) != 1 {
		t.Fatal("the export must be recorded")
	}
	if _, _, _, err := s.Export(ctx, mustID(t, otherHex), AuditQuery{Space: spaceHex}); err == nil {
		t.Fatal("a non-owner must not export a project's trail")
	}
}

func TestHandoverHoldsComputerActions(t *testing.T) {
	s, _, ctx := harness(t)
	if _, err := s.TakeControl(ctx, mustID(t, ownerHex), spaceHex); err != nil {
		t.Fatal(err)
	}
	go func() {
		time.Sleep(50 * time.Millisecond)
		if _, err := s.ReleaseControl(ctx, mustID(t, ownerHex), spaceHex, "logged in"); err != nil {
			t.Error(err)
		}
	}()
	start := time.Now()
	res, _ := s.Gate(ctx, req(gate.KindSandbox, "sandbox_exec", map[string]any{"command": "npm test"}))
	if !res.Allowed || time.Since(start) < 40*time.Millisecond {
		t.Fatalf("the action waits for the handover, then runs: %+v", res)
	}
	events, _, _ := s.Audit(ctx, mustID(t, ownerHex), AuditQuery{Space: spaceHex, Decision: gov.DecisionEvent})
	seen := map[string]bool{}
	for _, e := range events {
		seen[e.Event] = true
	}
	if !seen["computer.control_taken"] || !seen["computer.control_released"] {
		t.Fatalf("handover must be audited: %v", seen)
	}
}

func TestEgressPolicy(t *testing.T) {
	p := egress.Policy{Mode: egress.DefaultsPlus, Allow: []string{"*.example.com"}, Always: []string{"aseman"}}
	for host, want := range map[string]bool{
		"registry.npmjs.org": true, "api.example.com": true, "example.org": false, "aseman": true,
		"169.254.169.254": false, "metadata.google.internal": false,
	} {
		if got := p.AllowsHost(host); got != want {
			t.Errorf("%s: got %v", host, got)
		}
	}
	if (egress.Policy{Mode: egress.AllowAll}).AllowsHost("169.254.169.254") {
		t.Fatal("metadata is refused in every mode")
	}
	if (egress.Policy{Mode: egress.DenyAll}).AllowsHost("github.com") {
		t.Fatal("deny_all refuses")
	}
	s, _, ctx := harness(t)
	if _, err := s.SetEgress(ctx, mustID(t, ownerHex), spaceHex, egress.AllowlistOnly, []string{"api.stripe.com"}); err != nil {
		t.Fatal(err)
	}
	if res, _ := s.Gate(ctx, req(gate.KindSandbox, "sandbox_exec", map[string]any{"command": "curl https://evil.example/x"})); res.Allowed {
		t.Fatal("a command to a host the policy refuses must be refused")
	}
	if _, err := s.SetEgress(ctx, mustID(t, otherHex), spaceHex, egress.AllowAll, nil); err == nil {
		t.Fatal("only the project's owner sets its egress")
	}
}
