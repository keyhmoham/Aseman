// Package bots implements the bots namespace: VM (bot) lifecycle, bot metadata,
// bot host functions (global KV, network ops) and direct bot messaging.
package bots

import (
	"context"
	"encoding/json"
	"fmt"
	settings "github.com/tradera/tradera/plugins/actions/settings/models"
	"strings"
	"sync"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/jsonpatch"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/bots/dto"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/finance/models/wallet"
	dtoLLM "github.com/tradera/tradera/plugins/actions/llm/dto"
	"github.com/tradera/tradera/plugins/actions/llm/models"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/kvs"
	"github.com/tradera/tradera/plugins/actions/support/metasvc"
	"github.com/tradera/tradera/plugins/actions/support/models/kv"
	"github.com/tradera/tradera/plugins/actions/support/models/metadata"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/actions/usage/models"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// AttachmentResolver resolves and authorizes file ids attached to a message so
// the target bot sees what was shared. Implemented by the spaces service and
// wired by the composition root.
// AgentAsker serves direct messages to agents: a person's conversation runs
// in their home space, an agent's inside its run's space.
type AgentAsker interface {
	AskDirect(ctx context.Context, caller, botID identity.ID, body string, attachments []vmm.FileAttachment) (string, error)
}

type AttachmentResolver interface {
	ResolveAttachments(ctx context.Context, caller identity.ID, ids []string) ([]vmm.FileAttachment, error)
}

// Service implements bot operations.
type Service struct {
	// pricingFn replaces the settings namespace's price list (tests).
	pricingFn func(context.Context) settings.Pricing

	K     api.Kernel
	R     *repo.Repo
	M     *metasvc.Service
	KV    *kvs.Service
	L     *logger.Logger
	Files AttachmentResolver

	// Biller charges users for bot execution (wired by the composition root).
	Biller Biller

	// LLM is the admin-managed LLM provider registry: agents pick a provider +
	// model from it and their token usage is priced with its prices.
	LLM LLMPort

	// Usage records per-request LLM token consumption (wired by the root).
	UsageLog UsageRecorder

	// Agents routes direct messages to agent engines that run inside a
	// space sandbox (wired by the root).
	Agents AgentAsker

	// billedMu guards the per-bot token billing cursor (cumulative LLM tokens
	// already charged, so each execution bills only the delta).
	billedMu     sync.Mutex
	billedTokens map[identity.ID]tokenCursor

	// usageMu guards the per-bot token usage cursor (cumulative LLM tokens
	// already recorded, so each request records only its own delta).
	usageMu     sync.Mutex
	usageTokens map[identity.ID]tokenCursor
}

// NewService builds the bots service.
func NewService(k api.Kernel, r *repo.Repo, log *logger.Logger) *Service {
	return &Service{
		K: k, R: r,
		M:            &metasvc.Service{K: k, R: r},
		KV:           &kvs.Service{K: k, R: r},
		L:            log.Named("bots"),
		billedTokens: map[identity.ID]tokenCursor{},
		usageTokens:  map[identity.ID]tokenCursor{},
	}
}

// ResolveAttachments resolves a list of file ids into VM-facing attachment
// descriptors, delegating file lookup and authorization to the spaces service
// when wired.
func (s *Service) ResolveAttachments(ctx context.Context, caller identity.ID, ids []string) ([]vmm.FileAttachment, error) {
	if s.Files == nil {
		return nil, nil
	}
	return s.Files.ResolveAttachments(ctx, caller, ids)
}

// EnsureVM re-hydrates a bot's VM when the adapter lost its runtime state (e.g.
// the daemon restarted). Agent engines keep agent definitions in memory, so
// existing bot records must have their runtime rebuilt from the persisted spec
// before they can answer. No-op when the VM is still present.
func (s *Service) EnsureVM(ctx context.Context, rec *bot.Bot) error {
	if rec == nil || rec.VMID == "" {
		return errs.InvalidArgument("bot has no vm id")
	}
	if rec.VMType == bot.VMTypeDeepAgents || rec.VMType == bot.VMTypeMCP || rec.VMType == bot.VMTypeInstalled {
		vm := s.K.VMMFor(vmm.Type(rec.VMType))
		if vm == nil {
			return errs.New(errs.CodeUnavailable, "no "+string(rec.VMType)+" VMM adapter active")
		}
		if lc, ok := vm.(interface {
			EnsureAgent(ctx context.Context, agentName, specYML string) error
		}); ok {
			return lc.EnsureAgent(ctx, rec.VMID, rec.SpecYML)
		}
	}
	s.adoptVM(rec)
	return nil
}

// adoptVM tells a VM adapter what a bot's VM was created from. A VM that stops
// for real (a Modal sandbox) is recreated from it, and deleted by it (its
// workspace volume is found by name), which only the bot record still knows
// after a restart.
func (s *Service) adoptVM(rec *bot.Bot) {
	vm := s.K.VMMFor(vmm.Type(rec.VMType))
	if vm == nil {
		return
	}
	ad, ok := vm.(interface {
		Adopt(id string, spec vmm.VMSpec)
	})
	if !ok {
		return
	}
	res, _ := rec.ParseResources()
	if res == nil {
		res = &bot.ResourceProfile{}
	}
	ad.Adopt(rec.VMID, vmm.VMSpec{
		Name: rec.Name, Type: vmm.Type(rec.VMType), ImageRef: rec.ImageRef, Args: []string{"sleep", "infinity"},
		Resources: vmm.ResourceSpec{CPU: res.CPU, MemoryMB: res.Memory, DiskMB: res.Disk, MaxRuntimeSec: res.MaxRuntimeSec},
		Labels:    map[string]string{"tradera.bot_id": rec.ID.String()},
	})
}

// SkillConfig is a structured agent capability. The service renders it into
// the agent spec server-side (no raw yaml in the client).
type SkillConfig = dto.SkillConfig

// CreateBotRequest carries the VM deployment parameters.
type CreateBotRequest = dto.CreateBotRequest

// CreateBot deploys a bot: account, wallet, metadata, record and VM.
func (s *Service) CreateBot(ctx context.Context, owner identity.ID, req CreateBotRequest) (*bot.Bot, error) {
	if req.Kind == "" || req.Kind == bot.KindAgent {
		// Every agent runs on the deep agents runtime, whatever engine an
		// older client asks for.
		req.VMType = bot.AgentVMType(req.VMType)
	}
	vm := s.K.VMMFor(vmm.Type(req.VMType))
	if vm == nil {
		return nil, errs.New(errs.CodeUnavailable, "no VMM adapter active")
	}
	if req.Name == "" {
		return nil, errs.InvalidArgument("bot name required")
	}
	if req.VMType == "" {
		req.VMType = bot.VMTypeDocker
	}
	if req.Kind == "" {
		req.Kind = bot.KindAgent
	}
	// Every bot (agent or tool) is metered. Default pricing: 1 credit per
	// minute base, 1 credit per vCPU-min, per GB of RAM-min and per GB of
	// disk-min, plus token pricing for langchain agents (1 in / 2 out per 1000).
	if req.Cost.PerMinute <= 0 {
		req.Cost.PerMinute = 1
	}
	if req.Cost.CPUPerMin <= 0 {
		req.Cost.CPUPerMin = 1
	}
	if req.Cost.MemoryPerGBMin <= 0 {
		req.Cost.MemoryPerGBMin = 1
	}
	if req.Cost.DiskPerGBMin <= 0 {
		req.Cost.DiskPerGBMin = 1
	}
	if req.Cost.TokenInRate <= 0 {
		req.Cost.TokenInRate = 1
	}
	if req.Cost.TokenOutRate <= 0 {
		req.Cost.TokenOutRate = 2
	}
	switch req.Kind {
	case bot.KindAgent, bot.KindTool:
	default:
		return nil, errs.InvalidArgument("kind must be agent or tool")
	}
	if req.ImageRef == "" && req.SpecYML != "" {
		// Build an image from the yml spec first.
		img, err := vm.BuildImage(ctx, vmm.ImageSpec{
			Type: vmm.Type(req.VMType), Name: req.Name, YML: req.SpecYML,
		})
		if err != nil {
			return nil, err
		}
		req.ImageRef = img.Ref
	}
	// Resolve the structured form config into a concrete spec.
	switch req.Kind {
	case bot.KindAgent:
		if req.SpecYML == "" {
			// The agent's backbone must be one of the LLM providers + models
			// the node admin configured (empty picks the defaults).
			if s.LLM != nil && req.VMType == bot.VMTypeDeepAgents {
				p, m, err := s.LLM.Resolve(ctx, req.Provider, req.Model)
				if err != nil {
					return nil, err
				}
				req.Provider, req.Model = p.ID.String(), m.ID
			}
			spec, err := renderAgentSpec(req)
			if err != nil {
				return nil, err
			}
			req.SpecYML = spec
			img, err := vm.BuildImage(ctx, vmm.ImageSpec{
				Type: vmm.Type(req.VMType), Name: req.Name, YML: req.SpecYML,
			})
			if err != nil {
				return nil, err
			}
			req.ImageRef = img.Ref
		}
	case bot.KindTool:
		if req.ImageRef == "" && req.Module != "" {
			req.ImageRef = req.Module
		}
		if req.ImageRef == "" {
			return nil, errs.InvalidArgument(string(req.Kind) + " requires a module or image reference")
		}
	}
	node := s.K.NodeID()
	now := time.Now().UTC()

	accID, err := identity.New(node)
	if err != nil {
		return nil, err
	}
	walletID, err := identity.New(node)
	if err != nil {
		return nil, err
	}
	botID, err := identity.New(node)
	if err != nil {
		return nil, err
	}
	acc := &account.Account{
		Entity: entity.Entity{ID: accID, CreatedAt: now, UpdatedAt: now},
		Kind:   account.KindBot, Handle: req.Name, Status: account.StatusActive, MetadataID: accID,
	}
	if err := s.R.CreateID(ctx, "accounts", accID, acc); err != nil {
		return nil, err
	}
	meta := &metadata.Record{Owner: accID.String(),
		Tree:        metadata.Tree{"profile": map[string]any{"displayName": req.Name, "type": string(req.VMType)}},
		PublicPaths: []string{"/profile"}, Version: 1, UpdatedAt: now}
	if err := s.R.CreateID(ctx, "metadatas", accID, meta); err != nil {
		return nil, err
	}
	wal := &wallet.Wallet{ID: walletID, OwnerID: accID, Balance: 0, Locked: 0, UpdatedAt: now}
	if err := s.R.CreateID(ctx, "wallets", walletID, wal); err != nil {
		return nil, err
	}
	resJSON, _ := json.Marshal(req.Resources)
	costJSON, _ := json.Marshal(req.Cost)
	rec := &bot.Bot{
		Entity:  entity.Entity{ID: botID, CreatedAt: now, UpdatedAt: now},
		OwnerID: owner, AccountID: accID, Name: req.Name, Kind: req.Kind,
		VMType: req.VMType,
		Status: bot.StatusPending, ImageRef: req.ImageRef, SpecYML: req.SpecYML,
		Resources: string(resJSON), Cost: string(costJSON),
		Frontend: req.Frontend, FrontendRef: req.FrontendRef,
	}
	if err := s.R.CreateID(ctx, "bots", botID, rec); err != nil {
		return nil, err
	}
	// Deploy the VM.
	vspec := vmm.VMSpec{
		Name: req.Name, Type: vmm.Type(rec.VMType), ImageRef: req.ImageRef,
		Resources: vmm.ResourceSpec{CPU: req.Resources.CPU, MemoryMB: req.Resources.Memory,
			DiskMB: req.Resources.Disk, MaxRuntimeSec: req.Resources.MaxRuntimeSec},
		Environment: req.Env, Args: req.Args, YML: req.SpecYML,
		Labels: map[string]string{"tradera.bot_id": botID.String()},
	}
	if sv := req.Service; sv != nil {
		// Only tool backends get a name on the node's network, and only in
		// their own namespace of names.
		if !strings.HasPrefix(sv.ID, "tool-") || sv.Port <= 0 || sv.Port > 65535 {
			return nil, errs.InvalidArgument("invalid service")
		}
		vspec.Labels[vmm.LabelServiceID] = sv.ID
		vspec.Labels[vmm.LabelNetworkAlias] = sv.ID
		vspec.Labels[vmm.LabelServicePort] = fmt.Sprint(sv.Port)
		vspec.Resources.Network = sv.Network
	}
	created, err := vm.CreateVM(ctx, vspec)
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "create bot VM")
	}

	rec.VMID = created.ID
	rec.Status = bot.StatusFromVMM(string(created.Status))
	rec.StartedAt = &now
	if err := s.R.Update(ctx, "bots", botID, rec); err != nil {
		return nil, err
	}
	// Persist runtime entities (backend, spec, frontend, static files, ...)
	// under their contract keys. These are dynamic — future entity types need
	// no schema change, just a new key.
	for key, value := range req.Entities {
		if value == "" {
			continue
		}
		if err := s.PutEntity(ctx, owner, botID, key, []byte(value), entityMime(key)); err != nil {
			s.L.Warn("store bot entity", "bot_id", botID.String(), "key", key, "error", err)
		}
	}
	if req.Frontend != "" {
		if err := s.PutEntity(ctx, owner, botID, bot.EntityFrontend, []byte(req.Frontend), "text/plain"); err != nil {
			s.L.Warn("store bot frontend entity", "bot_id", botID.String(), "error", err)
		}
	}
	if req.WidgetDSL != "" {
		if err := s.PutEntity(ctx, owner, botID, bot.EntityWidget, []byte(req.WidgetDSL), ""); err != nil {
			s.L.Warn("store bot widget entity", "bot_id", botID.String(), "error", err)
		}
	}
	if req.Description != "" {
		_ = s.M.Patch(ctx, accID, jsonpatch.Patch{{
			Op: "set", Path: "profile/description", Value: req.Description,
		}})
	}
	s.L.Info("bot deployed", "bot_id", botID.String(), "vm", created.ID, "type", req.VMType)
	return rec, nil
}

// renderAgentSpec renders the structured agent form into the agent spec yml
// consumed by the langchain adapter.
func renderAgentSpec(req CreateBotRequest) (string, error) {
	if strings.TrimSpace(req.Instructions) == "" {
		return "", errs.InvalidArgument("agent requires instructions")
	}
	model := req.Model
	if model == "" {
		model = "gpt-4o-mini"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "name: %q\n", req.Name)
	if req.Description != "" {
		fmt.Fprintf(&b, "description: %q\n", req.Description)
	}
	if req.Provider != "" {
		fmt.Fprintf(&b, "provider: %q\n", req.Provider)
	}
	fmt.Fprintf(&b, "model: %q\n", model)
	b.WriteString("instructions: |\n  ")
	b.WriteString(strings.ReplaceAll(req.Instructions, "\n", "\n  "))
	b.WriteString("\n")
	if req.MaxTokens > 0 {
		fmt.Fprintf(&b, "max_tokens: %d\n", req.MaxTokens)
	}
	if req.AllowedTools != nil {
		raw, _ := json.Marshal(req.AllowedTools)
		fmt.Fprintf(&b, "allowed_tools: %s\n", raw)
	}
	if req.MaxTurns > 0 {
		fmt.Fprintf(&b, "max_turns: %d\n", req.MaxTurns)
	}
	if len(req.Skills) > 0 {
		b.WriteString("skills:\n")
		for _, s := range req.Skills {
			fmt.Fprintf(&b, "  - name: %q\n", s.Name)
			if s.Description != "" {
				fmt.Fprintf(&b, "    description: %q\n", s.Description)
			}
			if s.Instructions != "" {
				b.WriteString("    instructions: |\n      ")
				b.WriteString(strings.ReplaceAll(s.Instructions, "\n", "\n      "))
				b.WriteString("\n")
			}
			if len(s.Tools) > 0 {
				b.WriteString("    tools: [")
				b.WriteString(strings.Join(s.Tools, ", "))
				b.WriteString("]\n")
			}
		}
	}
	return b.String(), nil
}

// GetBot loads a bot by id.
func (s *Service) GetBot(ctx context.Context, id identity.ID) (*bot.Bot, error) {
	rec := &bot.Bot{}
	if err := s.R.Get(ctx, "bots", id, rec); err != nil {
		return nil, err
	}
	s.migrateAgentEngine(ctx, rec)
	return rec, nil
}

// migrateAgentEngine moves an agent recorded on an engine this node no longer
// runs onto the deep agents runtime. Its spec is engine-neutral (name, model,
// instructions, skills), so nothing else changes.
// migrateRetiredKinds turns bots stored under the retired "miniapp" kind into
// tools: an app is a tool, whatever it was created as.
func (s *Service) migrateRetiredKinds(ctx context.Context) {
	var old []bot.Bot
	if err := s.R.List(ctx, "bots", database.Filter{Equal: map[string]any{"kind": "miniapp"}}, &old); err != nil {
		return
	}
	for i := range old {
		old[i].Kind = bot.KindTool
		if err := s.R.Update(ctx, "bots", old[i].ID, &old[i]); err != nil {
			s.L.Warn("could not migrate an app to a tool", "bot", old[i].ID.String(), "error", err)
		}
	}
}

func (s *Service) migrateAgentEngine(ctx context.Context, rec *bot.Bot) {
	if rec.Kind != bot.KindAgent {
		return
	}
	want := bot.AgentVMType(rec.VMType)
	if want == rec.VMType {
		return
	}
	rec.VMType = want
	rec.UpdatedAt = time.Now().UTC()
	if err := s.R.Update(ctx, "bots", rec.ID, rec); err != nil {
		s.L.Warn("migrate agent engine", "bot", rec.ID.String(), "error", err)
		return
	}
	s.L.Info("agent moved to the deep agents runtime", "bot", rec.ID.String(), "name", rec.Name)
}

// Lifecycle maps a bot action onto the VMM and persists the status.
func (s *Service) Lifecycle(ctx context.Context, id identity.ID, op string) (*bot.Bot, error) {
	rec, err := s.GetBot(ctx, id)
	if err != nil {
		return nil, err
	}
	// start/resume need a live VM; rebuild it if the daemon restarted.
	if op == "start" || op == "resume" {
		if err := s.EnsureVM(ctx, rec); err != nil {
			return nil, err
		}
	}
	vm := s.K.VMMFor(vmm.Type(rec.VMType))
	if vm == nil {
		return nil, errs.New(errs.CodeUnavailable, "no VMM adapter active")
	}
	now := time.Now().UTC()
	switch op {
	case "start":
		err = vm.StartVM(ctx, rec.VMID)
		rec.Status = bot.StatusRunning
	case "stop":
		err = vm.StopVM(ctx, rec.VMID)
		rec.Status = bot.StatusStopped
	case "pause":
		err = vm.PauseVM(ctx, rec.VMID)
		rec.Status = bot.StatusPaused
	case "resume":
		err = vm.ResumeVM(ctx, rec.VMID)
		rec.Status = bot.StatusRunning
	}
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "vm "+op)
	}
	rec.UpdatedAt = now
	if op == "stop" {
		rec.StoppedAt = &now
	}
	if err := s.R.Update(ctx, "bots", id, rec); err != nil {
		return nil, err
	}
	return rec, nil
}

// Usage returns live metering for a bot VM.
func (s *Service) Usage(ctx context.Context, id identity.ID) (vmm.Usage, error) {
	rec, err := s.GetBot(ctx, id)
	if err != nil {
		return vmm.Usage{}, err
	}
	vm := s.K.VMMFor(vmm.Type(rec.VMType))
	if vm == nil {
		return vmm.Usage{}, errs.New(errs.CodeUnavailable, "no VMM adapter active")
	}
	return vm.Usage(ctx, rec.VMID)
}

// SendMessage delivers a message to a bot VM when supported. The optional
// history carries earlier conversational turns, and [attachments] are the
// files sent with this turn (agents see what was shared in chat).
func (s *Service) SendMessage(ctx context.Context, botID identity.ID, body string, attachments []vmm.FileAttachment, history []vmm.ChatMessage) (string, error) {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return "", err
	}
	// Rebuild the VM runtime when the daemon restarted and the adapter lost it.
	if err := s.EnsureVM(ctx, rec); err != nil {
		return "", err
	}
	vm := s.K.VMMFor(vmm.Type(rec.VMType))
	if vm == nil {
		return "", errs.New(errs.CodeUnavailable, "no VMM adapter active")
	}
	// Agents work in a space sandbox: a direct conversation runs in the
	// caller's space. Wasm app backends answer through their exported ask
	// host function. Everything else is recorded with no synchronous reply.
	switch rec.VMType {
	case bot.VMTypeDeepAgents:
		if s.Agents == nil {
			return "", errs.New(errs.CodeUnavailable, "agent routing not wired")
		}
		return s.Agents.AskDirect(ctx, helper.Actor(ctx), botID, body, attachments)
	case bot.VMTypeWASM, bot.VMTypeMCP, bot.VMTypeInstalled:
		// A wasm app's ask host function, or a remote MCP tool's call.
		if wm, ok := vm.(interface {
			Send(ctx context.Context, vmID, message string) (string, error)
		}); ok {
			return wm.Send(ctx, rec.VMID, body)
		}
	}
	return "", errs.New(errs.CodeUnavailable, "bot VM does not support messaging")
}

// Resize applies new resource limits to a bot's VM live.
func (s *Service) Resize(ctx context.Context, id identity.ID, res bot.ResourceProfile) (*bot.Bot, error) {
	rec, err := s.GetBot(ctx, id)
	if err != nil {
		return nil, err
	}
	vm := s.K.VMMFor(vmm.Type(rec.VMType))
	if vm == nil {
		return nil, errs.New(errs.CodeUnavailable, "no VMM adapter active")
	}
	_, err = vm.ResizeVM(ctx, rec.VMID, vmm.ResourceSpec{
		CPU: res.CPU, MemoryMB: res.Memory, DiskMB: res.Disk, MaxRuntimeSec: res.MaxRuntimeSec,
	})
	if err != nil {
		return nil, errs.Wrap(errs.CodeVMM, err, "resize vm")
	}
	resJSON, _ := json.Marshal(res)
	rec.Resources = string(resJSON)
	rec.UpdatedAt = time.Now().UTC()
	if err := s.R.Update(ctx, "bots", id, rec); err != nil {
		return nil, err
	}
	s.L.Info("bot resized", "bot_id", id.String(), "cpu", res.CPU, "memory_mb", res.Memory)
	return rec, nil
}

// BuildActions assembles the bots namespace actions.
func BuildActions(s *Service) []api.Action {
	return append([]api.Action{
		providerCatalogAction(s),
		&botCreateAction{s: s}, &botListAction{s: s}, &botGetAction{s: s},
		&botProfileAction{s: s},
		&botSearchAction{s: s},
		&builtinTraderaAction{s: s},
		&botLifecycleAction{s: s}, &botDeleteAction{s: s}, &botUsageAction{s: s},
		&botResizeAction{s: s},
		&botMessageAction{s: s}, &botMetaViewAction{s: s}, &botMetaPatchAction{s: s},
		&botKVSetAction{s: s}, &botKVGetAction{s: s}, &botKVListAction{s: s}, &botKVDeleteAction{s: s},
		&botNetworkCallAction{s: s},
		&botFrontendSetAction{s: s}, &botFrontendGetAction{s: s},
		&botWidgetSetAction{s: s}, &botWidgetGetAction{s: s},
		&botEntityPutAction{s: s}, &botEntityGetAction{s: s},
		&botEntityListAction{s: s}, &botEntityDeleteAction{s: s},
	}, editActions(s)...)
}

// Bot account lookup for bot-owned actions.
func (s *Service) BotAccount(ctx context.Context, accountID identity.ID) (*account.Account, error) {
	acc := &account.Account{}
	if err := s.R.Get(ctx, "accounts", accountID, acc); err != nil {
		return nil, err
	}
	if acc.Kind != account.KindBot {
		return nil, errs.Permission("action requires a bot account")
	}
	return acc, nil
}

// --- actions ---

type botCreateAction struct{ s *Service }

func (a *botCreateAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "bot_create", Summary: "Deploy a bot VM from an image or yml spec"}
}
func (a *botCreateAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in CreateBotRequest
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	// A name on the node's network is the node's to give (see ServiceSpec).
	in.Service = nil
	rec, err := a.s.CreateBot(ctx, req.Caller.ID, in)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"bot_id": rec.ID.String(), "vm_id": rec.VMID,
		"name": rec.Name, "status": rec.Status})
}

type botListAction struct{ s *Service }

func (a *botListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "bot_list", Summary: "List bots I own"}
}
func (a *botListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Limit  int `json:"limit,omitempty"`
		Offset int `json:"offset,omitempty"`
	}
	_ = helper.Decode(req, &in)
	limit, offset := helper.Paging(in.Limit, in.Offset, 50, 200)
	var list []bot.Bot
	if err := a.s.R.List(ctx, "bots", database.Filter{
		Equal:   map[string]any{"owner_id": req.Caller.ID.String()},
		OrderBy: "created_at", Asc: false, Limit: limit, Offset: offset,
	}, &list); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"bots": list})
}

type botGetAction struct{ s *Service }

func (a *botGetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "bot_get", Summary: "Get a bot"}
}
func (a *botGetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Bot string `json:"bot"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, err
	}
	if resp, ok, err := helper.ProxyIfRemote(ctx, a.s.K, in.Bot, "bots", "bot_get", req); ok {
		return resp, err
	}
	rec, err := a.s.GetBot(ctx, id)
	if err != nil {
		return nil, err
	}
	keys := []string{}
	if items, err := a.s.ListEntities(ctx, id); err == nil {
		for _, it := range items {
			keys = append(keys, it.Key)
		}
	}
	return helper.JSON(map[string]any{"id": rec.ID.String(), "owner_id": rec.OwnerID.String(),
		"name": rec.Name, "kind": rec.Kind, "vm_type": rec.VMType, "status": rec.Status, "vm_id": rec.VMID,
		"image_ref": rec.ImageRef, "has_frontend": rec.Frontend != "" || rec.FrontendRef != "",
		"entities": keys})
}

type botLifecycleAction struct{ s *Service }

func (a *botLifecycleAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "bot_lifecycle", Summary: "start/stop/pause/resume a bot VM"}
}
func (a *botLifecycleAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Bot string `json:"bot"`
		Op  string `json:"op"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, err
	}
	switch in.Op {
	case "start", "stop", "pause", "resume":
	default:
		return nil, errs.InvalidArgument("op must be start|stop|pause|resume")
	}
	rec, err := a.s.GetBot(ctx, id)
	if err != nil {
		return nil, err
	}
	if rec.OwnerID != req.Caller.ID {
		return nil, errs.Permission("not the bot owner")
	}
	rec2, err := a.s.Lifecycle(ctx, id, in.Op)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"bot_id": id.String(), "status": rec2.Status})
}

// DeleteBot permanently deletes a bot VM and its record.
func (s *Service) DeleteBot(ctx context.Context, caller, botID identity.ID) error {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return err
	}
	if rec.OwnerID != caller && rec.AccountID != caller {
		return errs.Permission("not the bot owner")
	}
	if vm := s.K.VMMFor(vmm.Type(rec.VMType)); vm != nil {
		s.adoptVM(rec)
		if err := vm.DeleteVM(ctx, rec.VMID); err != nil {
			s.L.Warn("delete bot vm", "bot", botID.String(), "vm", rec.VMID, "error", err)
		}
	}
	return s.R.Delete(ctx, "bots", botID)
}

type botDeleteAction struct{ s *Service }

func (a *botDeleteAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "bot_delete", Summary: "Delete a bot VM permanently"}
}
func (a *botDeleteAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Bot string `json:"bot"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, err
	}
	caller := req.Caller.ID
	if rec, e := a.s.GetBot(ctx, id); e == nil {
		if IsTradera(rec) {
			return nil, errs.Permission("the built-in tradera agent cannot be deleted")
		}
		// A node admin may remove any bot (e.g. an ownerless or orphaned one).
		if rec.OwnerID != caller && rec.AccountID != caller &&
			helper.RequireNodeAdmin(ctx, a.s.R, req, a.s.K.Env()["admin_handle"]) == nil {
			caller = rec.OwnerID
		}
	}
	if err := a.s.DeleteBot(ctx, caller, id); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

type botUsageAction struct{ s *Service }

func (a *botUsageAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "bot_usage", Summary: "Live resource usage of a bot VM"}
}
func (a *botUsageAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Bot string `json:"bot"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, err
	}
	u, err := a.s.Usage(ctx, id)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"usage": u})
}

// botResizeAction implements bots.bot_resize.
type botResizeAction struct{ s *Service }

func (a *botResizeAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "bot_resize", Summary: "Apply new resource limits to a running bot VM"}
}
func (a *botResizeAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Bot           string  `json:"bot"`
		CPU           float64 `json:"cpu"`
		MemoryMB      int64   `json:"memory_mb"`
		DiskMB        int64   `json:"disk_mb"`
		MaxRuntimeSec int64   `json:"max_runtime_sec,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, err
	}
	rec, err := a.s.GetBot(ctx, id)
	if err != nil {
		return nil, err
	}
	if rec.OwnerID != req.Caller.ID {
		return nil, errs.Permission("not the bot owner")
	}
	res := bot.ResourceProfile{CPU: in.CPU, Memory: in.MemoryMB, Disk: in.DiskMB, MaxRuntimeSec: in.MaxRuntimeSec}
	updated, err := a.s.Resize(ctx, id, res)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"bot_id": id.String(), "status": updated.Status, "resized": true})
}

type botMessageAction struct{ s *Service }

func (a *botMessageAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "bot_message", Summary: "Message a bot VM"}
}
func (a *botMessageAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Bot         string            `json:"bot"`
		Body        string            `json:"body"`
		History     []vmm.ChatMessage `json:"history,omitempty"`
		Attachments []string          `json:"attachments,omitempty"` // file ids sent with the message
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, err
	}
	atts, err := a.s.ResolveAttachments(ctx, req.Caller.ID, in.Attachments)
	if err != nil {
		return nil, err
	}
	// The built-in tradera agent is the workflow orchestrator: route its asks
	// there instead of a wasm VM.
	rec, err := a.s.GetBot(ctx, id)
	if err != nil {
		return nil, err
	}
	if IsTradera(rec) {
		return a.s.routeTradera(ctx, req.Caller.ID, in.Body)
	}
	// Hard enforcement: the caller must be able to pay before the VM runs.
	if err := a.s.EnsureFunds(ctx, req.Caller.ID, id); err != nil {
		return nil, err
	}
	start := time.Now()
	reply, err := a.s.SendMessage(ctx, id, in.Body, atts, in.History)
	if err != nil {
		return nil, err
	}
	if err := a.s.BillUsage(ctx, req.Caller.ID, id, int64(time.Since(start).Seconds()), "message"); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"reply": reply})
}

type botMetaViewAction struct{ s *Service }

func (a *botMetaViewAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "metadata_view", Summary: "View a bot metadata tree"}
}
func (a *botMetaViewAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Bot string `json:"bot"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, err
	}
	rec, err := a.s.GetBot(ctx, id)
	if err != nil {
		return nil, err
	}
	var owner identity.ID
	if rec.AccountID == req.Caller.ID || rec.OwnerID == req.Caller.ID {
		owner = rec.AccountID
	}
	view, err := a.s.M.View(ctx, owner, rec.AccountID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"owner": view.Owner, "tree": view.Tree,
		"public_paths": view.PublicPaths})
}

type botMetaPatchAction struct{ s *Service }

func (a *botMetaPatchAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "metadata_patch", Summary: "Patch bot metadata"}
}
func (a *botMetaPatchAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Bot   string          `json:"bot"`
		Tree  metadata.Tree   `json:"tree,omitempty"`
		Patch jsonpatch.Patch `json:"patch,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, err
	}
	rec, err := a.s.GetBot(ctx, id)
	if err != nil {
		return nil, err
	}
	if rec.AccountID != req.Caller.ID && rec.OwnerID != req.Caller.ID {
		return nil, errs.Permission("not authorized to modify this bot's metadata")
	}
	if in.Tree != nil {
		if err := a.s.M.ReplaceTree(ctx, rec.AccountID, in.Tree); err != nil {
			return nil, err
		}
	}
	return helper.JSON(map[string]any{"ok": true})
}

type botKVSetAction struct{ s *Service }

func (a *botKVSetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "kv_set", Summary: "Set bot global KV value (host function)"}
}
func (a *botKVSetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Key   string `json:"key"`
		Value string `json:"value"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if err := a.s.KV.Set(ctx, kv.ScopeGlobal, identity.ID{}, req.Caller.ID, in.Key, in.Value); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

type botKVGetAction struct{ s *Service }

func (a *botKVGetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "kv_get", Summary: "Get bot global KV value"}
}
func (a *botKVGetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Key string `json:"key"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	item, err := a.s.KV.Get(ctx, kv.ScopeGlobal, identity.ID{}, req.Caller.ID, in.Key)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"key": item.Key, "value": item.Value})
}

type botKVListAction struct{ s *Service }

func (a *botKVListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "kv_list", Summary: "List bot global KV entries"}
}
func (a *botKVListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Limit  int `json:"limit,omitempty"`
		Offset int `json:"offset,omitempty"`
	}
	_ = helper.Decode(req, &in)
	limit, offset := helper.Paging(in.Limit, in.Offset, 50, 200)
	items, err := a.s.KV.Range(ctx, kv.ScopeGlobal, identity.ID{}, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	start := offset
	if start > len(items) {
		start = len(items)
	}
	end := len(items)
	if limit > 0 && start+limit < end {
		end = start + limit
	}
	return helper.JSON(map[string]any{"items": items[start:end]})
}

type botKVDeleteAction struct{ s *Service }

func (a *botKVDeleteAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "kv_delete", Summary: "Delete bot global KV value"}
}
func (a *botKVDeleteAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Key string `json:"key"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if err := a.s.KV.Delete(ctx, kv.ScopeGlobal, identity.ID{}, req.Caller.ID, in.Key); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

type botNetworkCallAction struct{ s *Service }

func (a *botNetworkCallAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "network_call", Summary: "Bot host function: make an outbound network call"}
}
func (a *botNetworkCallAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireBot(req); err != nil {
		return nil, err
	}
	var in struct {
		Protocol string            `json:"protocol"` // http
		Addr     string            `json:"addr"`
		Method   string            `json:"method"`
		Path     string            `json:"path"`
		Header   map[string]string `json:"header,omitempty"`
		Body     []byte            `json:"body,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	net := a.s.K.Network()
	if net == nil {
		return nil, errs.New(errs.CodeUnavailable, "no network adapter active")
	}
	if in.Protocol == "" {
		in.Protocol = "http"
	}
	method := network.Method(in.Method)
	if method == "" {
		method = network.MethodPost
	}
	resp, err := net.Call(ctx, in.Addr, &network.Request{
		Method: method, Path: in.Path, Header: in.Header, Body: in.Body,
	})
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"status": resp.Status, "body": string(resp.Body)})
}

// SetFrontend stores (or clears) the elpian bundle an app serves to
// clients. Only the bot owner/account may set it. The canonical copy lives in
// the bot's entity store under the frontend contract key.
func (s *Service) SetFrontend(ctx context.Context, caller identity.ID, botID identity.ID, bundle string, bundleRef string) (*bot.Bot, error) {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return nil, err
	}
	if rec.OwnerID != caller && rec.AccountID != caller {
		return nil, errs.Permission("not the bot owner")
	}
	if bundle != "" {
		if err := s.PutEntity(ctx, caller, botID, bot.EntityFrontend, []byte(bundle), "text/plain"); err != nil {
			return nil, err
		}
	} else {
		_ = s.DeleteEntity(ctx, caller, botID, bot.EntityFrontend)
	}
	rec.Frontend = bundle
	rec.FrontendRef = bundleRef
	rec.UpdatedAt = time.Now().UTC()
	if err := s.R.Update(ctx, "bots", botID, rec); err != nil {
		return nil, err
	}
	return rec, nil
}

// Frontend returns the elpian bundle of a bot, reading the entity store first
// and falling back to the legacy column. App frontends are public to
// authenticated users (they run sandboxed in the client); backend access is
// still gated by user-signed asks.
func (s *Service) Frontend(ctx context.Context, botID identity.ID) (string, error) {
	if ent, err := s.GetEntity(ctx, botID, bot.EntityFrontend); err == nil && len(ent.Value) > 0 {
		return string(ent.Value), nil
	}
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return "", err
	}
	if rec.Frontend == "" && rec.FrontendRef != "" {
		return "", errs.New(errs.CodeUnavailable, "frontend stored as external ref: "+rec.FrontendRef)
	}
	return rec.Frontend, nil
}

type botFrontendSetAction struct{ s *Service }

func (a *botFrontendSetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "frontend_set", Summary: "Set the elpian frontend bundle of an app"}
}
func (a *botFrontendSetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Bot         string `json:"bot"`
		Frontend    string `json:"frontend,omitempty"`
		FrontendRef string `json:"frontend_ref,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, err
	}
	rec, err := a.s.SetFrontend(ctx, req.Caller.ID, id, in.Frontend, in.FrontendRef)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"bot_id": id.String(), "has_frontend": rec.Frontend != "" || rec.FrontendRef != "", "ok": true})
}

type botFrontendGetAction struct{ s *Service }

func (a *botFrontendGetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "bots", Name: "frontend_get", Summary: "Fetch the elpian frontend bundle of an app"}
}
func (a *botFrontendGetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Bot string `json:"bot"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Bot)
	if err != nil {
		return nil, err
	}
	if resp, ok, err := helper.ProxyIfRemote(ctx, a.s.K, in.Bot, "bots", "frontend_get", req); ok {
		return resp, err
	}
	bundle, err := a.s.Frontend(ctx, id)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"bot_id": id.String(), "frontend": bundle})
}

// LLMPort is the provider registry surface consumed by agent execution.
type LLMPort interface {
	Resolve(ctx context.Context, provider, model string) (*llmprovider.Provider, llmprovider.Model, error)
	PriceFor(ctx context.Context, provider, model string) (dtoLLM.Price, error)
}

// UsageRecorder is the write-only ledger bridge.
type UsageRecorder interface {
	Record(context.Context, *usage.Usage) error
}
