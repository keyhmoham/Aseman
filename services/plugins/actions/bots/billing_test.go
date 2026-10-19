package bots

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/bots/dto"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/llm"
	"github.com/tradera/tradera/plugins/actions/llm/models"
	settings "github.com/tradera/tradera/plugins/actions/settings/models"
	usage "github.com/tradera/tradera/plugins/actions/usage/models"
)

type recordingBiller struct {
	calls []billCall
	// ctxErrs is the context error each charge saw: a real wallet write fails
	// on a cancelled context.
	ctxErrs []error
	gates   []identity.ID
	gateErr error
}

type billCall struct {
	customer, botOwner, nodeOwner identity.ID
	amount                        int64
	desc                          string
}

func (r *recordingBiller) Charge(ctx context.Context, customer, botOwner, nodeOwner identity.ID, amount int64, desc string) error {
	r.ctxErrs = append(r.ctxErrs, ctx.Err())
	r.calls = append(r.calls, billCall{customer, botOwner, nodeOwner, amount, desc})
	return nil
}

func (r *recordingBiller) EnsureFunds(_ context.Context, customer identity.ID, _ int64) error {
	r.gates = append(r.gates, customer)
	return r.gateErr
}

func TestBillUsageChargesCustomerWithCostModel(t *testing.T) {
	s, ctx, _, _ := entityHarness(t)
	biller := &recordingBiller{}
	s.Biller = biller

	// Create a priced tool owned by someone else.
	other := mustID(t, "00000000000000010000000000000009")
	botID, _ := identity.New(1)
	now := time.Now().UTC()
	rec := &bot.Bot{
		Entity:  entity.Entity{ID: botID, CreatedAt: now, UpdatedAt: now},
		OwnerID: other, Name: "priced", Kind: bot.KindTool,
		VMType: bot.VMTypeWASM, Status: bot.StatusRunning,
		Cost: `{"per_minute":3}`,
	}
	if err := s.R.CreateID(ctx, "bots", botID, rec); err != nil {
		t.Fatal(err)
	}
	// A connected app (a remote MCP server) is free to call, whatever its record says.
	appID, _ := identity.New(1)
	app := &bot.Bot{Entity: entity.Entity{ID: appID, CreatedAt: now, UpdatedAt: now}, OwnerID: other, Name: "app", Kind: bot.KindTool, VMType: bot.VMType("mcp"), Status: bot.StatusRunning, Cost: `{"per_minute":3}`}
	if err := s.R.CreateID(ctx, "bots", appID, app); err != nil {
		t.Fatal(err)
	}
	if err := s.BillUsage(ctx, mustID(t, "00000000000000010000000000000001"), appID, 60, "ask"); err != nil || len(biller.calls) != 0 {
		t.Fatalf("a connected app was charged: %v %+v", err, biller.calls)
	}
	if min, err := s.MinCost(ctx, appID); err != nil || min != 0 {
		t.Fatalf("a connected app needs funds to call: %d %v", min, err)
	}

	customer := mustID(t, "00000000000000010000000000000001")
	if err := s.BillUsage(ctx, customer, botID, 60, "ask"); err != nil {
		t.Fatal(err)
	}
	if len(biller.calls) != 1 {
		t.Fatalf("expected 1 bill call, got %d", len(biller.calls))
	}
	c := biller.calls[0]
	if c.customer != customer || c.botOwner != other || c.amount != 3 {
		t.Fatalf("bill call mismatch: %+v", c)
	}
}

func TestBillUsageDefaultsFreeBotsToOneCreditPerMinute(t *testing.T) {
	s, ctx, owner, botID := entityHarness(t)
	biller := &recordingBiller{}
	s.Biller = biller
	// entityHarness seeds a miniapp with no cost model.
	if err := s.BillUsage(ctx, owner, botID, 30, "run"); err != nil {
		t.Fatal(err)
	}
	if len(biller.calls) != 1 {
		t.Fatalf("expected 1 bill call, got %d", len(biller.calls))
	}
	if biller.calls[0].amount != 1 {
		t.Fatalf("amount = %d, want 1 (minimum metering)", biller.calls[0].amount)
	}
}

func TestBillUsageNoopWithoutBiller(t *testing.T) {
	s, ctx, owner, botID := entityHarness(t)
	if err := s.BillUsage(ctx, owner, botID, 60, "run"); err != nil {
		t.Fatalf("expected no-op without biller, got %v", err)
	}
}

func TestEnsureFundsGatesExecution(t *testing.T) {
	s, ctx, _, _ := entityHarness(t)
	biller := &recordingBiller{}
	s.Biller = biller

	customer := mustID(t, "00000000000000010000000000000001")
	botID, _ := identity.New(1)
	now := time.Now().UTC()
	rec := &bot.Bot{
		Entity:  entity.Entity{ID: botID, CreatedAt: now, UpdatedAt: now},
		OwnerID: customer, Name: "priced", Kind: bot.KindAgent,
		VMType: bot.VMTypeDeepAgents, Status: bot.StatusRunning,
		Cost: `{"per_minute":4}`,
	}
	if err := s.R.CreateID(ctx, "bots", botID, rec); err != nil {
		t.Fatal(err)
	}

	// Passing gate → no error.
	if err := s.EnsureFunds(ctx, customer, botID); err != nil {
		t.Fatalf("ensure funds: %v", err)
	}
	if len(biller.gates) != 1 {
		t.Fatalf("expected 1 gate call, got %d", len(biller.gates))
	}

	// Failing gate → hard error propagated.
	biller.gateErr = errors.New("insufficient balance")
	if err := s.EnsureFunds(ctx, customer, botID); err == nil {
		t.Fatal("expected hard enforcement error")
	}
}

func mustID(t *testing.T, h string) identity.ID {
	t.Helper()
	id, err := identity.Parse(h)
	if err != nil {
		t.Fatal(err)
	}
	return id
}
func TestMeterCostCombinesResourcesTimeAndTokens(t *testing.T) {
	cost := &bot.CostModel{PerMinute: 1, CPUPerMin: 1, MemoryPerGBMin: 1, DiskPerGBMin: 1, TokenInRate: 1, TokenOutRate: 2}
	// 2 vCPU, 2048MB RAM, 1024MB disk, 60s → minutes=1
	res := &bot.ResourceProfile{CPU: 2, Memory: 2048, Disk: 1024}
	// resource = (2*1 + 2048*1/1024 + 1024*1/1024) * 1 = 2 + 2 + 1 = 5
	// time = 1*1 = 1; tokens = 1000in*1/1000 + 500out*2/1000 = 1 + 1 = 2
	// total = 5 + 1 + 2 = 8
	got := meterCost(cost, res, 60, 1000, 500)
	if got != 8 {
		t.Fatalf("meterCost = %d, want 8", got)
	}

	// Free bot (no rates) still costs the minimum.
	got = meterCost(&bot.CostModel{}, &bot.ResourceProfile{}, 30, 0, 0)
	if got != 1 {
		t.Fatalf("free bot cost = %d, want 1", got)
	}

	// Time is prorated: 90s at 6 credits/min = 9.
	got = meterCost(cost, res, 90, 0, 0)
	if got != 9 {
		t.Fatalf("90s cost = %d, want 9", got)
	}
	// A 2s command at 6/min is 0.2 credits, rounded up to 1 — not a minute.
	if got = meterCost(cost, res, 2, 0, 0); got != 1 {
		t.Fatalf("2s cost = %d, want 1", got)
	}
	// The per-call price is added once per execution.
	withCall := *cost
	withCall.PerCall = 25
	if got = meterCost(&withCall, res, 30, 0, 0); got != 28 { // 25 + ceil(6×30/60)
		t.Fatalf("per-call cost = %d, want 28", got)
	}
}

func TestLLMChargeUsesAdminProviderPrices(t *testing.T) {
	s, ctx, _, _ := entityHarness(t)
	s.LLM = llm.NewService(s.K, s.R, logger.Global())
	admin := mustID(t, "00000000000000010000000000000042")
	p, err := s.LLM.(*llm.Service).Set(ctx, admin, llm.ProviderInput{Kind: llmprovider.KindOpenAI, APIKey: "sk-x",
		Models: []llmprovider.Model{{ID: "gpt-5.4", InputPrice: 1000, OutputPrice: 4000}}})
	if err != nil {
		t.Fatal(err)
	}
	rec := &bot.Bot{Kind: bot.KindAgent, VMType: bot.VMTypeDeepAgents,
		SpecYML: "name: a\nprovider: \"" + p.ID.String() + "\"\nmodel: \"gpt-5.4\"\n"}
	// 3000 in × 1000/1M = 3, 500 out × 4000/1M = 2, plus 20 credits of images.
	amount, payee := s.llmCharge(ctx, rec, &bot.CostModel{TokenInRate: 99, TokenOutRate: 99}, 3000, 500, 20)
	if amount != 25 || payee != admin {
		t.Fatalf("llm charge = %d to %s, want 25 to the key owner", amount, payee)
	}
	// No usage → no charge.
	if amount, _ := s.llmCharge(ctx, rec, &bot.CostModel{}, 0, 0, 0); amount != 0 {
		t.Fatalf("idle charge = %d", amount)
	}
}

func TestLLMChargeFallsBackToBotRatesWithoutRegistry(t *testing.T) {
	s, ctx, _, _ := entityHarness(t)
	amount, payee := s.llmCharge(ctx, &bot.Bot{}, &bot.CostModel{TokenInRate: 1, TokenOutRate: 2}, 1000, 1000, 0)
	if amount != 3 || !payee.IsZero() {
		t.Fatalf("fallback = %d %v", amount, payee)
	}
}

func TestAgentBackbone(t *testing.T) {
	p, m := AgentBackbone("name: x\nprovider: \"abc\"\nmodel: \"gpt-5.4\"\ninstructions: |\n  hi\n")
	if p != "abc" || m != "gpt-5.4" {
		t.Fatalf("got %q %q", p, m)
	}
	if p, m := AgentBackbone("::bad"); p != "" || m != "" {
		t.Fatal("bad yml must yield empty backbone")
	}
}

func TestRenderAgentSpecIncludesProvider(t *testing.T) {
	spec, err := renderAgentSpec(CreateBotRequest{Name: "a", Instructions: "do", Provider: "p1", Model: "m1"})
	if err != nil {
		t.Fatal(err)
	}
	if p, m := AgentBackbone(spec); p != "p1" || m != "m1" {
		t.Fatalf("spec backbone %q %q in:\n%s", p, m, spec)
	}
}

func TestCostForAppliesPlatformPricing(t *testing.T) {
	s := &Service{pricingFn: func(context.Context) settings.Pricing {
		return settings.Pricing{
			Sandbox:        settings.Rate{PerMinute: 5, CPUPerMin: 2, MemoryPerGBMin: 1, DiskPerGBMin: 1},
			Tool:           settings.Rate{PerMinute: 3, CPUPerMin: 1},
			AgentPerMinute: 7,
		}
	}}
	ctx := context.Background()
	cases := []struct {
		name string
		rec  bot.Bot
		want bot.CostModel
	}{
		{"the sandbox always follows the platform", bot.Bot{Name: "sbx-1", Kind: bot.KindTool, VMType: bot.VMTypeContainer, Cost: `{"per_minute":1}`},
			bot.CostModel{PerMinute: 5, CPUPerMin: 2, MemoryPerGBMin: 1, DiskPerGBMin: 1}},
		{"a tool without rates gets the tool defaults", bot.Bot{Name: "weather", Kind: bot.KindMiniapp, VMType: bot.VMTypeWASM},
			bot.CostModel{PerMinute: 3, CPUPerMin: 1}},
		{"a tool keeps its own rates", bot.Bot{Name: "render", Kind: bot.KindTool, VMType: bot.VMType("mcp"), Cost: `{"per_minute":0,"cpu_per_min":4}`},
			bot.CostModel{CPUPerMin: 4}},
		{"an agent without a rate gets the agent default", bot.Bot{Name: "coder", Kind: bot.KindAgent, VMType: bot.VMTypeDeepAgents, Cost: `{"token_in_rate":2}`},
			bot.CostModel{PerMinute: 7, TokenInRate: 2}},
		{"an agent keeps its own rate", bot.Bot{Name: "pro", Kind: bot.KindAgent, VMType: bot.VMTypeDeepAgents, Cost: `{"per_minute":9}`},
			bot.CostModel{PerMinute: 9}},
	}
	for _, c := range cases {
		if got := *s.costFor(ctx, &c.rec); got != c.want {
			t.Errorf("%s: got %+v, want %+v", c.name, got, c.want)
		}
	}
}

func TestMeterCostPricesFractionalResources(t *testing.T) {
	// 0.5 vCPU × 4 + 512MB × 2/GB = 2 + 1 = 3 per minute, for 2 minutes.
	got := meterCost(&bot.CostModel{CPUPerMin: 4, MemoryPerGBMin: 2}, &bot.ResourceProfile{CPU: 0.5, Memory: 512}, 120, 0, 0)
	if got != 6 {
		t.Fatalf("meterCost = %d, want 6", got)
	}
}

func TestBillUsageLeavesRuntimeAgentsToTheirTurns(t *testing.T) {
	s, ctx, _, _ := entityHarness(t)
	biller := &recordingBiller{}
	s.Biller = biller
	botID, _ := identity.New(1)
	now := time.Now().UTC()
	rec := &bot.Bot{Entity: entity.Entity{ID: botID, CreatedAt: now, UpdatedAt: now}, OwnerID: mustID(t, "00000000000000010000000000000009"),
		Name: "coder", Kind: bot.KindAgent, VMType: bot.VMTypeDeepAgents, Status: bot.StatusRunning, Cost: `{"per_minute":3}`}
	if err := s.R.CreateID(ctx, "bots", botID, rec); err != nil {
		t.Fatal(err)
	}
	if err := s.BillUsage(ctx, mustID(t, "00000000000000010000000000000001"), botID, 60, "message"); err != nil || len(biller.calls) != 0 {
		t.Fatalf("a runtime agent was billed outside its turn: %v, %+v", err, biller.calls)
	}
	// Its turns are billed through BillAndRecordUsage.
	if _, err := s.BillAndRecordUsage(ctx, mustID(t, "00000000000000010000000000000001"), botID, 60, "agent turn", usage.UsageCtx{}); err != nil || len(biller.calls) != 1 || biller.calls[0].amount != 3 {
		t.Fatalf("agent turn billing = %v, %+v", err, biller.calls)
	}
}

func TestSandboxExecutionPaysTheNode(t *testing.T) {
	s, ctx, _, _ := entityHarness(t)
	biller := &recordingBiller{}
	s.Biller = biller
	s.pricingFn = func(context.Context) settings.Pricing {
		return settings.Pricing{Sandbox: settings.Rate{PerMinute: 4}}
	}
	botID, _ := identity.New(1)
	now := time.Now().UTC()
	spaceOwner := mustID(t, "00000000000000010000000000000009")
	rec := &bot.Bot{Entity: entity.Entity{ID: botID, CreatedAt: now, UpdatedAt: now}, OwnerID: spaceOwner,
		Name: "sbx-1", Kind: bot.KindTool, VMType: bot.VMTypeContainer, Status: bot.StatusRunning}
	if err := s.R.CreateID(ctx, "bots", botID, rec); err != nil {
		t.Fatal(err)
	}
	// A command on the computer is not billed by itself...
	if err := s.BillUsage(ctx, mustID(t, "00000000000000010000000000000001"), botID, 30, "sandbox exec"); err != nil || len(biller.calls) != 0 {
		t.Fatalf("a command was billed on its own: %v, %+v", err, biller.calls)
	}
	// ...the time it is awake is.
	if err := s.BillUsage(ctx, mustID(t, "00000000000000010000000000000001"), botID, 30, dto.ComputerTimeDesc); err != nil {
		t.Fatal(err)
	}
	if len(biller.calls) != 1 || biller.calls[0].amount != 2 || biller.calls[0].botOwner == spaceOwner {
		t.Fatalf("sandbox charge = %+v; want 2 credits paid to the node, not the space owner", biller.calls)
	}
}

func TestAStoppedTurnIsStillCharged(t *testing.T) {
	s, ctx, _, _ := entityHarness(t)
	biller := &recordingBiller{}
	s.Biller = biller
	other := mustID(t, "00000000000000010000000000000009")
	botID, _ := identity.New(1)
	now := time.Now().UTC()
	rec := &bot.Bot{Entity: entity.Entity{ID: botID, CreatedAt: now, UpdatedAt: now}, OwnerID: other, Name: "priced", Kind: bot.KindTool,
		VMType: bot.VMTypeWASM, Status: bot.StatusRunning, Cost: `{"per_minute":3}`}
	if err := s.R.CreateID(ctx, "bots", botID, rec); err != nil {
		t.Fatal(err)
	}
	// The person stopped the turn: its context is cancelled when it is charged.
	stopped, cancel := context.WithCancel(ctx)
	cancel()
	customer := mustID(t, "00000000000000010000000000000001")
	if err := s.BillUsage(stopped, customer, botID, 60, "ask"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.BillAndRecordUsage(stopped, customer, botID, 60, "turn", usage.UsageCtx{}); err != nil {
		t.Fatal(err)
	}
	if len(biller.calls) != 2 || biller.calls[0].amount != 3 {
		t.Fatalf("a stopped turn went unpaid: %+v", biller.calls)
	}
	for _, err := range biller.ctxErrs {
		if err != nil {
			t.Fatalf("the charge ran on the stopped turn's context, where the wallet write fails: %v", err)
		}
	}
}
