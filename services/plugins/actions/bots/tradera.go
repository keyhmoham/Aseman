package bots

import (
	"context"
	"os"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/finance/models/wallet"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/models/metadata"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"gopkg.in/yaml.v3"
)

// builtinTraderaImage is the reserved image ref marking the built-in
// orchestrator's bot record (kept stable so existing records stay recognised).
const builtinTraderaImage = bot.BuiltinTraderaImage

// traderaVMID is the deep agents runtime VM id of the built-in lead.
const traderaVMID = "deepagents-tradera"

// IsTradera reports whether a bot record is the built-in orchestrator agent.
func IsTradera(rec *bot.Bot) bool {
	return rec.IsBuiltinLead()
}

// traderaSpec is the built-in lead's agent spec. The "lead" role makes the
// runtime run it as the swarm's leader: it plans, delegates to the space's
// agents over room messages and recruits new ones. Its LLM backbone can be
// pinned with TRADERA_ORCHESTRATOR_PROVIDER/_MODEL; otherwise it follows the
// node's default provider.
//
// An admin can pin the backbone from the admin console (bots.bot_edit); the
// existing spec's provider/model then win over the environment, which only
// seeds a lead that has none.
func traderaSpec(existing string) string {
	spec := map[string]any{
		"name":         "tradera",
		"role":         "lead",
		"description":  "The space's lead agent: plans the work, delegates to the space's agents, recruits specialists and delivers the outcome.",
		"instructions": "You are tradera, the lead agent of every Tradera space. You help the people of the space directly and lead the space's agents to get larger work done end to end.",
	}
	if p := strings.TrimSpace(os.Getenv("TRADERA_ORCHESTRATOR_PROVIDER")); p != "" {
		spec["provider"] = p
	}
	if m := strings.TrimSpace(os.Getenv("TRADERA_ORCHESTRATOR_MODEL")); m != "" {
		spec["model"] = m
	}
	// A name the admin gave it survives restarts.
	var prior struct {
		Name string `yaml:"name"`
	}
	if yaml.Unmarshal([]byte(existing), &prior) == nil && strings.TrimSpace(prior.Name) != "" {
		spec["name"] = strings.TrimSpace(prior.Name)
	}
	if provider, model := AgentBackbone(existing); provider != "" || model != "" {
		spec["provider"], spec["model"] = provider, model
		if provider == "" {
			delete(spec, "provider")
		}
		if model == "" {
			delete(spec, "model")
		}
	}
	out, _ := yaml.Marshal(spec)
	return string(out)
}

// legacyTraderaCost is the price older nodes hard-coded on the lead.
var legacyTraderaCost = bot.CostModel{PerMinute: 1, CPUPerMin: 1, MemoryPerGBMin: 1, DiskPerGBMin: 1, TokenInRate: 1, TokenOutRate: 2}

// hasLegacyCost reports whether the lead still carries that hard-coded price
// (compared by value: databases may store the JSON reformatted).
func hasLegacyCost(rec *bot.Bot) bool {
	c, err := rec.ParseCost()
	return err == nil && c != nil && *c == legacyTraderaCost
}

// InstallTradera creates (idempotently) the built-in "tradera" lead agent.
// It runs on the deep agents runtime like every agent, with the lead role.
// Older records are upgraded in place. Returns the bot record.
func (s *Service) InstallTradera(ctx context.Context) (*bot.Bot, error) {
	// Idempotent: reuse an existing built-in tradera bot.
	var existing []bot.Bot
	if err := s.R.List(ctx, "bots", database.Filter{
		Equal: map[string]any{"image_ref": builtinTraderaImage}, // not by name: the admin may rename it
	}, &existing); err == nil && len(existing) > 0 {
		rec := &existing[0]
		if spec := traderaSpec(rec.SpecYML); rec.VMType != bot.VMTypeDeepAgents || rec.VMID != traderaVMID || rec.SpecYML != spec || hasLegacyCost(rec) {
			rec.VMType, rec.VMID, rec.SpecYML = bot.VMTypeDeepAgents, traderaVMID, spec
			// The lead is priced by the platform's agent rate.
			if hasLegacyCost(rec) {
				rec.Cost, rec.Resources = "", ""
			}
			rec.Kind, rec.Status = bot.KindAgent, bot.StatusRunning
			rec.UpdatedAt = time.Now().UTC()
			if err := s.R.Update(ctx, "bots", rec.ID, rec); err != nil {
				return nil, err
			}
			s.L.Info("builtin tradera lead moved to the deep agents runtime", "bot_id", rec.ID.String())
		}
		return rec, nil
	}
	node := s.K.NodeID()
	now := time.Now().UTC()

	accID, err := identity.New(node)
	if err != nil {
		return nil, err
	}
	walID, err := identity.New(node)
	if err != nil {
		return nil, err
	}
	botID, err := identity.New(node)
	if err != nil {
		return nil, err
	}

	acc := &account.Account{
		Entity: entity.Entity{ID: accID, CreatedAt: now, UpdatedAt: now},
		Kind:   account.KindBot, Handle: "tradera", Status: account.StatusActive, MetadataID: accID,
	}
	if err := s.R.CreateID(ctx, "accounts", accID, acc); err != nil {
		return nil, err
	}
	meta := &metadata.Record{Owner: accID.String(),
		Tree: metadata.Tree{"profile": map[string]any{
			"displayName": "tradera",
			"description": "Built-in agent orchestrator: plans tasks, dispatches them to the workspace's agents and tools, tracks progress and keeps shared memory.",
		}},
		PublicPaths: []string{"/profile"}, Version: 1, UpdatedAt: now,
	}
	if err := s.R.CreateID(ctx, "metadatas", accID, meta); err != nil {
		return nil, err
	}
	wal := &wallet.Wallet{ID: walID, OwnerID: accID, Balance: 0, Locked: 0, UpdatedAt: now}
	if err := s.R.CreateID(ctx, "wallets", walID, wal); err != nil {
		return nil, err
	}
	rec := &bot.Bot{
		Entity:  entity.Entity{ID: botID, CreatedAt: now, UpdatedAt: now},
		OwnerID: identity.ID{}, AccountID: accID, Name: "tradera",
		Kind: bot.KindAgent, VMType: bot.VMTypeDeepAgents, VMID: traderaVMID,
		Status: bot.StatusRunning, ImageRef: builtinTraderaImage, SpecYML: traderaSpec(""),
		// No cost of its own: the lead is billed at the platform's agent rate
		// (Settings → Pricing) plus its model's token prices.
	}
	if err := s.R.CreateID(ctx, "bots", botID, rec); err != nil {
		return nil, err
	}
	s.L.Info("builtin tradera agent installed", "bot_id", botID.String(), "account_id", accID.String())
	return rec, nil
}

// builtinTraderaAction implements bots.builtin_tradera (or
// admin.install_tradera): create/return the built-in orchestrator agent.
type builtinTraderaAction struct{ s *Service }

func (a *builtinTraderaAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "builtin_tradera", Summary: "Install the built-in tradera agent orchestrator (idempotent)"}
}
func (a *builtinTraderaAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	rec, err := a.s.InstallTradera(ctx)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{
		"bot_id": rec.ID.String(), "account_id": rec.AccountID.String(),
		"name": rec.Name, "kind": rec.Kind, "vm_type": rec.VMType, "ok": true,
	})
}

// IsTradera loads a bot and reports whether it is the built-in orchestrator.
func (s *Service) IsTradera(ctx context.Context, botID identity.ID) (bool, error) {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return false, err
	}
	return IsTradera(rec), nil
}

// RunTradera executes a task with the built-in orchestrator in the caller's
// home workspace (used by the message namespace for direct asks to tradera).
func (s *Service) RunTradera(ctx context.Context, caller identity.ID, task string) (map[string]any, error) {
	if s.Agents == nil {
		return nil, errs.New(errs.CodeUnavailable, "tradera agent routing not wired")
	}
	rec, err := s.InstallTradera(ctx)
	if err != nil {
		return nil, err
	}
	reply, err := s.Agents.AskDirect(helper.WithActor(ctx, caller), caller, rec.ID, task, nil)
	if err != nil {
		return nil, err
	}
	return map[string]any{"bot_id": rec.ID.String(), "status": "done", "result": reply}, nil
}

// routeTradera is the bots.bot_message handler for asks directed at tradera.
func (s *Service) routeTradera(ctx context.Context, caller identity.ID, task string) (*api.ActionResponse, error) {
	result, err := s.RunTradera(ctx, caller, task)
	if err != nil {
		return nil, err
	}
	return helper.JSON(result)
}

// Bootstrap moves every agent still recorded on a retired engine onto the deep
// agents runtime and installs the built-in lead.
func (s *Service) Bootstrap(ctx context.Context) error {
	var agents []bot.Bot
	if err := s.R.List(ctx, "bots", database.Filter{Equal: map[string]any{"kind": string(bot.KindAgent)}}, &agents); err != nil {
		return err
	}
	for i := range agents {
		s.migrateAgentEngine(ctx, &agents[i])
	}
	_, err := s.InstallTradera(ctx)
	return err
}
