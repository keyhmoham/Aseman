package bots

import (
	"context"
	"fmt"
	"math"

	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/bots/dto"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/finance/models/wallet"
	settings "github.com/tradera/tradera/plugins/actions/settings/models"
	"github.com/tradera/tradera/plugins/actions/usage/models"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// Biller charges a customer's wallet for bot/sandbox execution and credits the
// bot owner / node owner. Implemented by the finance service and wired by the
// composition root.
type Biller interface {
	// Charge debits an exact credit amount and pays the owners.
	Charge(ctx context.Context, customer, botOwner, nodeOwner identity.ID, amount int64, desc string) error
	// EnsureFunds is the hard-enforcement gate: it fails when the customer's
	// wallet cannot cover a minimum metered cost.
	EnsureFunds(ctx context.Context, customer identity.ID, minCost int64) error
}

// Metering constants (integer credits).
const (
	// Minimum cost for any execution.
	minExecutionCredits int64 = 1
	// Token accounting scale: rates are per 1000 tokens.
	tokenScale int64 = 1000
)

// meterCost computes the cost of one execution:
//
//   - its time: (per_minute + vCPUs×cpu/min + RAM GB×ram/GB/min + disk GB×
//     disk/GB/min), prorated to the seconds it ran;
//   - its call: per_call, once;
//   - its LLM tokens at the bot's own token rates (per 1000 tokens), when no
//     provider prices them.
//
// Executions shorter than a second count as one second; a priced execution
// costs at least one credit (fractions are rounded up).
func meterCost(cost *bot.CostModel, res *bot.ResourceProfile, seconds, tokensIn, tokensOut int64) int64 {
	if seconds < 1 {
		seconds = 1
	}
	perMinute := float64(cost.PerMinute)
	if res != nil {
		perMinute += math.Max(res.CPU, 0)*float64(cost.CPUPerMin) +
			float64(max(res.Memory, 0))/1024*float64(cost.MemoryPerGBMin) +
			float64(max(res.Disk, 0))/1024*float64(cost.DiskPerGBMin)
	}
	timeCost := int64(math.Ceil(perMinute*float64(seconds)/60 - 1e-9))
	tokenCost := tokensIn*cost.TokenInRate/tokenScale + tokensOut*cost.TokenOutRate/tokenScale
	total := timeCost + max(cost.PerCall, 0) + tokenCost
	if total <= 0 {
		return minExecutionCredits
	}
	return total
}

// pricing is the node's execution price list (the settings namespace's), or
// the defaults when it cannot be read.
func (s *Service) pricing(ctx context.Context) settings.Pricing {
	if s.pricingFn != nil {
		return s.pricingFn(ctx)
	}
	p := settings.DefaultPricing()
	if s.K != nil {
		_ = bridge.Invoke(ctx, s.K, "settings", "Pricing", []any{ctx}, &p)
	}
	return p
}

// costFor is the cost model a bot is billed with:
//
//   - a space's sandbox is priced by the platform (the sandbox rate);
//   - a tool or miniapp uses the execution rates set on it, or the platform's
//     tool rates when it has none;
//   - an agent uses its own per-minute rate, or the platform's agent rate,
//     and no resource rates (its machine, the sandbox, is billed apart).
//
// Token, image and per-call prices always come from the bot itself.
func (s *Service) costFor(ctx context.Context, rec *bot.Bot) *bot.CostModel {
	cost, err := rec.ParseCost()
	if err != nil || cost == nil {
		cost = &bot.CostModel{}
	}
	out := *cost
	apply := func(r settings.Rate) {
		out.PerMinute, out.CPUPerMin, out.MemoryPerGBMin, out.DiskPerGBMin = r.PerMinute, r.CPUPerMin, r.MemoryPerGBMin, r.DiskPerGBMin
	}
	switch {
	case rec.IsSandbox():
		apply(s.pricing(ctx).Sandbox)
	case rec.Kind == bot.KindTool || rec.Kind == bot.KindMiniapp:
		if !cost.ExecutionPriced() {
			apply(s.pricing(ctx).Tool)
		}
	case rec.Kind == bot.KindAgent:
		// An agent is priced by its time; the machine it works on (the space
		// sandbox) is billed on its own, so no resource rates apply to it.
		out.CPUPerMin, out.MemoryPerGBMin, out.DiskPerGBMin = 0, 0, 0
		if cost.PerMinute == 0 {
			out.PerMinute = s.pricing(ctx).AgentPerMinute
		}
	}
	return &out
}

// EffectiveCost is the cost model a bot is billed with (see costFor).
func (s *Service) EffectiveCost(ctx context.Context, botID identity.ID) (bot.CostModel, error) {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return bot.CostModel{}, err
	}
	return *s.costFor(ctx, rec), nil
}

// MinCost returns the minimum metered cost (credits) for running a bot once:
// one minute of resources + execution time, ignoring tokens.
func (s *Service) MinCost(ctx context.Context, botID identity.ID) (int64, error) {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return 0, err
	}
	if rec.VMType == bot.VMType("mcp") {
		return 0, nil // a connected app is free to call
	}
	cost := s.costFor(ctx, rec)
	res, err := rec.ParseResources()
	if err != nil || res == nil {
		res = &bot.ResourceProfile{}
	}
	return meterCost(cost, res, 60, 0, 0), nil
}

// EnsureFunds gates an execution: the customer must be able to cover at least
// the minimum metered cost of the bot before the VM runs. A no-op when no
// biller is wired.
func (s *Service) EnsureFunds(ctx context.Context, customer, botID identity.ID) error {
	if s.Biller == nil {
		return nil
	}
	minCost, err := s.MinCost(ctx, botID)
	if err != nil {
		return err
	}
	return s.Biller.EnsureFunds(ctx, customer, minCost)
}

// EnsureBalance gates an action on a flat credit floor (e.g. a mention that
// will trigger one or more metered agents). A no-op when no biller is wired.
func (s *Service) EnsureBalance(ctx context.Context, customer identity.ID, minCost int64) error {
	if s.Biller == nil {
		return nil
	}
	return s.Biller.EnsureFunds(ctx, customer, minCost)
}

// GateRun is the check a run makes while it is still working, before it spends
// more: the payer's wallet and the project's budget (taken from ctx's
// execution scope) must still cover everything the run has used so far — its
// time and its model tokens, which are only settled when it ends — plus one
// credit. It is what stops a long run at the budget instead of one run past it.
func (s *Service) GateRun(ctx context.Context, customer, botID identity.ID, seconds, tokensIn, tokensOut int64) error {
	if s.Biller == nil {
		return nil
	}
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return err
	}
	cost := s.costFor(ctx, rec)
	res, err := rec.ParseResources()
	if err != nil || res == nil {
		res = &bot.ResourceProfile{}
	}
	pending := meterCost(cost, res, seconds, 0, 0) + s.llmChargeAmount(ctx, rec, cost, usage.Delta{TokensIn: tokensIn, TokensOut: tokensOut})
	return s.Biller.EnsureFunds(ctx, customer, pending+1)
}

// LineCharger is the optional multi-line charging capability of the biller
// (implemented by the finance service): it debits the customer once for the
// execution and the LLM usage lines.
type LineCharger interface {
	ChargeLines(ctx context.Context, customer identity.ID, desc string, lines []wallet.ChargeLine) error
}

// BillUsage meters a bot execution and charges the customer:
//
//   - execution (resources + execution time), split between the bot owner and
//     the node owner as before;
//   - LLM usage of langchain agents (token delta since the last meter, priced
//     with the input/output prices the node admin set for the agent's
//     provider + model, plus generated images), paid entirely to the account
//     that owns the provider's API key.
//
// The returned error is propagated so the caller can hard-fail the action when
// the customer cannot pay.
func (s *Service) BillUsage(ctx context.Context, customer, botID identity.ID, seconds int64, desc string) error {
	if s.Biller == nil {
		return nil
	}
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return err
	}
	// A project's computer is billed for the time it is awake (ComputerTimeDesc),
	// not command by command: idle minutes and a watched desktop cost the
	// platform too.
	if rec.IsSandbox() && desc != dto.ComputerTimeDesc {
		return nil
	}
	// A connected app (a remote MCP server) runs on its provider's machines,
	// not this node's: calling it costs the project nothing here.
	if rec.VMType == bot.VMType("mcp") {
		return nil
	}
	// An agent on the deep agents runtime bills each of its turns where the
	// turn runs (with its own duration and tokens); billing it again here
	// would charge the same work twice.
	if rec.Kind == bot.KindAgent && bot.AgentVMType(rec.VMType) == bot.VMTypeDeepAgents {
		return nil
	}
	cost := s.costFor(ctx, rec)
	res, err := rec.ParseResources()
	if err != nil || res == nil {
		res = &bot.ResourceProfile{}
	}
	delta, err := s.billingDelta(ctx, rec)
	if err != nil {
		return err
	}
	return s.chargeDelta(ctx, customer, rec, cost, res, seconds, delta, desc)
}

// BillAndRecordUsage meters a bot execution, bills the customer (execution +
// LLM tokens) and records the request's LLM token usage into the usage ledger,
// attributed to the space/room/bot/request in [uc]. It returns the metered
// delta so callers can append the token summary to the agent's reply.
func (s *Service) BillAndRecordUsage(ctx context.Context, customer, botID identity.ID, seconds int64, desc string, uc usage.UsageCtx) (usage.Delta, error) {
	if s.Biller == nil {
		return usage.Delta{}, nil
	}
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return usage.Delta{}, err
	}
	if rec.IsSandbox() {
		return usage.Delta{}, nil // billed by awake time, see BillUsage
	}
	if rec.VMType == bot.VMType("mcp") {
		return usage.Delta{}, nil // a connected app is free to call, see BillUsage
	}
	cost := s.costFor(ctx, rec)
	res, err := rec.ParseResources()
	if err != nil || res == nil {
		res = &bot.ResourceProfile{}
	}
	billDelta, err := s.billingDelta(ctx, rec)
	if err != nil {
		return usage.Delta{}, err
	}
	usageDelta, err := s.usageDelta(ctx, rec)
	if err != nil {
		return usage.Delta{}, err
	}
	if err := s.chargeDelta(ctx, customer, rec, cost, res, seconds, billDelta, desc); err != nil {
		return usage.Delta{}, err
	}
	usageDelta.Cost = s.llmChargeAmount(ctx, rec, cost, usageDelta)
	s.recordDelta(ctx, customer, rec.ID, usageDelta, uc)
	return usageDelta, nil
}

// RecordUsage meters a bot's LLM token consumption since the last recorded
// usage and records it into the usage ledger without charging (used by the
// orchestrator for the agents it dispatches inside a workflow). It returns the
// delta so callers can append the token summary to an agent's reply.
func (s *Service) RecordUsage(ctx context.Context, actor, botID identity.ID, uc usage.UsageCtx) (usage.Delta, error) {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return usage.Delta{}, err
	}
	delta, err := s.usageDelta(ctx, rec)
	if err != nil {
		return usage.Delta{}, err
	}
	if delta.Zero() {
		return delta, nil
	}
	cost := s.costFor(ctx, rec)
	delta.Cost = s.llmChargeAmount(ctx, rec, cost, delta)
	s.recordDelta(ctx, actor, rec.ID, delta, uc)
	return delta, nil
}

// billingDelta computes a bot's cumulative LLM token consumption since the last
// billed meter and advances the billing cursor.
func (s *Service) billingDelta(ctx context.Context, rec *bot.Bot) (usage.Delta, error) {
	if u := vmm.InvocationFrom(ctx); u != nil {
		return u.Take(true), nil
	}
	u, uerr := s.Usage(ctx, rec.ID)
	if uerr != nil {
		return usage.Delta{}, nil
	}
	s.billedMu.Lock()
	last := s.billedTokens[rec.ID]
	d := usage.Delta{
		TokensIn:  max(u.TokensIn-last.In, 0),
		TokensOut: max(u.TokensOut-last.Out, 0),
		Images:    int64(math.Max(u.ImageCredits-last.Images, 0)),
	}
	s.billedTokens[rec.ID] = tokenCursor{In: u.TokensIn, Out: u.TokensOut, Images: u.ImageCredits}
	s.billedMu.Unlock()
	return d, nil
}

// usageDelta computes a bot's cumulative LLM token consumption since the last
// recorded usage and advances the usage cursor (so each request records only
// its own delta). Returns a zero delta when the VM has no meter yet.
func (s *Service) usageDelta(ctx context.Context, rec *bot.Bot) (usage.Delta, error) {
	if u := vmm.InvocationFrom(ctx); u != nil {
		return u.Take(false), nil
	}
	u, uerr := s.Usage(ctx, rec.ID)
	if uerr != nil {
		return usage.Delta{}, nil
	}
	s.usageMu.Lock()
	last := s.usageTokens[rec.ID]
	d := usage.Delta{
		TokensIn:  max(u.TokensIn-last.In, 0),
		TokensOut: max(u.TokensOut-last.Out, 0),
		Images:    int64(math.Max(u.ImageCredits-last.Images, 0)),
	}
	s.usageTokens[rec.ID] = tokenCursor{In: u.TokensIn, Out: u.TokensOut, Images: u.ImageCredits}
	s.usageMu.Unlock()
	return d, nil
}

// RecordDelta records a fixed usage delta into the ledger without metering a
// VM (used by tradera to log its own orchestrator brain's token usage, which
// is not tied to a bot VM meter).
func (s *Service) RecordDelta(ctx context.Context, actor, botID identity.ID, d usage.Delta, uc usage.UsageCtx) error {
	if d.Zero() || uc.SpaceID.IsZero() {
		return nil
	}
	if s.UsageLog == nil {
		return nil
	}
	provider, model := "", ""
	if rec, e := s.GetBot(ctx, botID); e == nil {
		provider, model = AgentBackbone(rec.SpecYML)
	}
	return s.UsageLog.Record(ctx, &usage.Usage{
		SpaceID: uc.SpaceID, RoomID: uc.RoomID, BotID: botID, Provider: provider, Model: model,
		BotName: uc.BotName, ActorID: actor,
		RequestID: uc.RequestID, Kind: uc.Kind,
		TokensIn: d.TokensIn, TokensOut: d.TokensOut, Images: d.Images, Cost: d.Cost,
	})
}

// recordDelta persists a metered delta into the usage ledger (best-effort) so
// token spend is tracked per space / room / bot / request.
func (s *Service) recordDelta(ctx context.Context, actor, botID identity.ID, d usage.Delta, uc usage.UsageCtx) {
	_ = s.RecordDelta(ctx, actor, botID, d, uc)
}

// chargeDelta performs the actual wallet charge for a metered execution: the
// execution cost split between the bot owner and node owner, and the LLM cost
// paid entirely to the API key owner.
func (s *Service) chargeDelta(ctx context.Context, customer identity.ID, rec *bot.Bot, cost *bot.CostModel, res *bot.ResourceProfile, seconds int64, delta usage.Delta, desc string) error {
	execAmount := meterCost(cost, res, seconds, 0, 0)
	llmAmount, payee := s.llmCharge(ctx, rec, cost, delta.TokensIn, delta.TokensOut, float64(delta.Images+delta.Decision))
	nodeOwner := s.NodeOwnerID(ctx)
	if payee.IsZero() {
		payee = nodeOwner
	}
	// Execution is split between the bot's owner and the node; the space
	// sandbox is the node's own machine, so the node is paid for all of it.
	execPayees := []identity.ID{rec.OwnerID, nodeOwner}
	execTypes := []wallet.EntryType{wallet.EntryPayBot, wallet.EntryPayNode}
	category := wallet.CategoryAgent
	switch {
	case rec.IsSandbox():
		if nodeOwner.IsZero() {
			// Nobody to pay means the charge would vanish without a trace.
			s.L.Warn("computer time has no node owner to be paid to: it is not charged or recorded", "bot", rec.ID.String())
		}
		execPayees, execTypes = []identity.ID{nodeOwner}, []wallet.EntryType{wallet.EntryPayNode}
		category = wallet.CategoryCompute
	case rec.Kind == bot.KindTool || rec.Kind == bot.KindMiniapp:
		category = wallet.CategoryTool
	}
	if lc, ok := s.Biller.(LineCharger); ok {
		return lc.ChargeLines(ctx, customer, desc, []wallet.ChargeLine{
			{Amount: execAmount, Payees: execPayees, PayeeTypes: execTypes, Desc: desc, Category: category, Bot: rec.ID.String()},
			{Amount: llmAmount, Payees: []identity.ID{payee}, Type: wallet.EntryPayLLM, Category: wallet.CategoryLLM, Bot: rec.ID.String(),
				Desc: fmt.Sprintf("llm usage %s (%d in / %d out tokens)", desc, delta.TokensIn, delta.TokensOut)},
		})
	}
	botOwner := rec.OwnerID
	if rec.IsSandbox() {
		botOwner = nodeOwner
	}
	if err := s.Biller.Charge(ctx, customer, botOwner, nodeOwner, execAmount, desc); err != nil {
		return err
	}
	if llmAmount > 0 {
		return s.Biller.Charge(ctx, customer, identity.ID{}, payee, llmAmount, "llm usage "+desc)
	}
	return nil
}

// llmChargeAmount prices a metered delta with the admin-set prices of the
// bot's provider + model (0 when no provider registry prices it).
func (s *Service) llmChargeAmount(ctx context.Context, rec *bot.Bot, cost *bot.CostModel, delta usage.Delta) int64 {
	amount, _ := s.llmCharge(ctx, rec, cost, delta.TokensIn, delta.TokensOut, float64(delta.Images+delta.Decision))
	return amount
}

// llmCharge prices an agent's LLM usage with the admin-set prices of its
// provider + model and returns the amount and the API key owner to pay. When
// no provider registry is available it falls back to the bot's own token
// rates (paid to the node owner, signalled by a zero payee). [images] is the
// already priced extras: generated images and the decision model's charges.
func (s *Service) llmCharge(ctx context.Context, rec *bot.Bot, cost *bot.CostModel, tokensIn, tokensOut int64, images float64) (int64, identity.ID) {
	var imageAmount int64
	if images > 0 {
		imageAmount = int64(math.Ceil(images - 1e-9))
	}
	if tokensIn == 0 && tokensOut == 0 && imageAmount == 0 {
		return 0, identity.ID{}
	}
	if s.LLM != nil {
		provider, model := AgentBackbone(rec.SpecYML)
		if price, err := s.LLM.PriceFor(ctx, provider, model); err == nil {
			return price.TokenCost(tokensIn, tokensOut) + imageAmount, price.Payee
		}
	}
	return tokensIn*cost.TokenInRate/tokenScale + tokensOut*cost.TokenOutRate/tokenScale + imageAmount, identity.ID{}
}

// AgentBackbone extracts the LLM provider and model from an agent's yml spec.
func AgentBackbone(specYML string) (provider, model string) { return bot.AgentBackbone(specYML) }

type tokenCursor struct {
	In     int64
	Out    int64
	Images float64
}

// NodeOwnerID resolves the account that operates this node (the admin handle)
// so infrastructure charges can be paid to it. Zero when unknown.
func (s *Service) NodeOwnerID(ctx context.Context) identity.ID {
	if handle := s.K.Env()["admin_handle"]; handle != "" {
		var list []account.Account
		if s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"handle": handle}}, &list) == nil &&
			len(list) > 0 {
			return list[0].ID
		}
	}
	// The bootstrap admin can change its handle (it stays an admin by role):
	// the node is then owned by its longest-standing admin. Without this the
	// node's share of every charge had nobody to go to, and computer time,
	// which is paid to the node alone, was never charged or recorded.
	var admins []account.Account
	if s.R.List(ctx, "accounts", database.Filter{
		Equal: map[string]any{"role": "admin", "kind": string(account.KindUser)}, OrderBy: "created_at", Asc: true, Limit: 5,
	}, &admins) == nil {
		for _, a := range admins {
			if a.Status == account.StatusActive {
				return a.ID
			}
		}
	}
	return identity.ID{}
}
