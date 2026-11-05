// Package bot defines the VM-backed bot entity. Every running VM in the
// federated network is a bot. The bot's lifecycle is managed through the VMM
// port; its financials through the finance services.
package bot

import (
	"strings"

	"gopkg.in/yaml.v3"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
)

// Kind classifies what a bot is used for. Agents are LLM-driven assistants
// (served by the agent runtime); a tool is an app: a backend (MCP,
// wasm, a program) and the frontend it is used through.
type Kind string

const (
	KindAgent Kind = "agent"
	KindTool  Kind = "tool"
	// KindTheme is an installable UI theme pack (no VM). Pack JSON lives under
	// the bot entity key static/theme.json.
	KindTheme Kind = "theme"
)

// VMType supported by the VMM layer.
type VMType string

const (
	// VMTypeContainer is a standalone Docker Engine container (the shared
	// per-space sandbox when sandbox.backend=docker). Distinct from
	// VMTypeDocker (Nomad docker jobs) so VMMFor resolves it unambiguously.
	VMTypeContainer VMType = "container"
	VMTypeDocker    VMType = "docker"
	VMTypeWASM      VMType = "wasm"
	VMTypeModal     VMType = "modal"
	// VMTypeHarness is an agent served by the agent runtime (DeepSeek
	// Harness). Every agent (the built-in aseman lead and every market agent)
	// runs on it.
	VMTypeHarness VMType = "harness"
	// VMTypeElpian / VMTypeQuickJS are managed tool backends: Elpian VM or
	// QuickJS programs run by the tool runtime image as Nomad services.
	VMTypeElpian  VMType = "elpian"
	VMTypeQuickJS VMType = "quickjs"
	// VMTypeMCP is a tool whose backend is an external MCP server.
	VMTypeMCP VMType = "mcp"
	// VMTypeInstalled is a tool backend installed into the sandbox of every
	// space that adds it, with no machine of its own.
	VMTypeInstalled VMType = "installed"
)

// IsToolBackend reports whether the bot is a tool whose backend answers
// microtool calls over MCP (an external server, a managed runtime, or one
// installed into a space sandbox), as opposed to the space sandbox itself or
// a wasm app.
func (b *Bot) IsToolBackend() bool {
	if b == nil || b.Kind == KindAgent || b.IsSandbox() {
		return false
	}
	switch b.VMType {
	case VMTypeMCP, VMTypeElpian, VMTypeQuickJS, VMTypeInstalled, VMTypeDocker:
		return true
	}
	return false
}

// AgentVMType maps the agent engine a record or request names onto the one
// agent runtime. Engines this node no longer runs ("deepagents", "opencode",
// "langchain", "grok") are served by the harness, so older records and older
// clients keep working.
func AgentVMType(t VMType) VMType {
	switch t {
	case "deepagents", "opencode", "deepseek", "langchain", "grok", "":
		return VMTypeHarness
	}
	return t
}

// VMMType is the VMM that serves the bot: an agent recorded on an earlier
// engine is served by the agent runtime.
func (b *Bot) VMMType() VMType {
	if b.Kind == KindAgent {
		return AgentVMType(b.VMType)
	}
	return b.VMType
}

// Status lifecycle states of a bot VM.
type Status string

const (
	StatusPending  Status = "pending"
	StatusCreating Status = "creating"
	StatusRunning  Status = "running"
	StatusStopped  Status = "stopped"
	StatusPaused   Status = "paused"
	StatusEnded    Status = "ended"
	StatusFailed   Status = "failed"
)

// ResourceProfile describes the resource limits/requests of a bot VM.
type ResourceProfile struct {
	CPU           float64 `json:"cpu"`    // vCPU
	Memory        int64   `json:"memory"` // MB
	Disk          int64   `json:"disk"`   // MB
	MaxRuntimeSec int64   `json:"max_runtime_sec,omitempty"`
}

// CostModel prices the bot execution. Billing is metered per minute across
// three dimensions and summed:
//
//   - execution time  → PerMinute × minutes
//   - VM resources    → (cpu×CPUPerMin) + (ramGB×MemoryPerGBMin) + (diskGB×DiskPerGBMin) × minutes
//   - LLM tokens      → tokensIn×TokenInRate/1000 + tokensOut×TokenOutRate/1000 (langchain agents)
//
// Amounts are integer credits.
type CostModel struct {
	PerMinute int64 `json:"per_minute"` // base execution time rate (credits/min)
	// PerCall is a flat price for every call of the bot (a tool
	// call), on top of the time and resources it runs for.
	PerCall   int64 `json:"per_call,omitempty"`
	ImageCost int64 `json:"image_cost,omitempty"`

	// Resource rates (credits per minute per unit).
	CPUPerMin      int64 `json:"cpu_per_min,omitempty"`       // per vCPU
	MemoryPerGBMin int64 `json:"memory_per_gb_min,omitempty"` // per GB RAM
	DiskPerGBMin   int64 `json:"disk_per_gb_min,omitempty"`   // per GB disk

	// Token rates (credits per 1000 tokens).
	TokenInRate  int64 `json:"token_in_rate,omitempty"`  // input (prompt) tokens
	TokenOutRate int64 `json:"token_out_rate,omitempty"` // output (completion) tokens
}

// Bot is a VM operating as a federation participant.
type Bot struct {
	entity.Entity
	OwnerID   identity.ID `db:"owner_id" json:"owner_id"` // account that deploys the VM
	AccountID identity.ID `db:"account_id" json:"account_id"`
	Name      string      `db:"name" json:"name"`
	Kind      Kind        `db:"kind" json:"kind,omitempty"` // agent | tool
	VMType    VMType      `db:"vm_type" json:"vm_type"`
	Status    Status      `db:"status" json:"status"`
	VMID      string      `db:"vm_id" json:"vm_id,omitempty"` // provider VM id
	ImageRef  string      `db:"image_ref" json:"image_ref,omitempty"`
	SpecYML   string      `db:"spec_yml" json:"-"`                    // the VM configuration yml
	Resources string      `db:"resources" json:"resources,omitempty"` // JSON ResourceProfile
	Cost      string      `db:"cost" json:"cost,omitempty"`           // JSON CostModel
	PoolID    string      `db:"pool_id" json:"pool_id,omitempty"`     // finance pool id
	// PlatformID scopes the bot to a sub-platform (empty = main Aseman).
	PlatformID string `db:"platform_id" json:"platform_id,omitempty"`
	// Frontend is the elpian mini-app bundle (JSON manifest + source) served to
	// clients that launch the bot's UI inside an elpian sandbox.
	Frontend string `db:"frontend" json:"frontend,omitempty"`
	// FrontendRef optionally points at a stored file/ref hosting the bundle.
	FrontendRef string     `db:"frontend_ref" json:"frontend_ref,omitempty"`
	StartedAt   *time.Time `db:"started_at" json:"started_at,omitempty"`
	StoppedAt   *time.Time `db:"stopped_at" json:"stopped_at,omitempty"`
}

// ParseResources decodes the resource profile JSON column.
func (b *Bot) ParseResources() (*ResourceProfile, error) {
	var p ResourceProfile
	if b.Resources == "" {
		return &p, nil
	}
	if err := unmarshalJSON(b.Resources, &p); err != nil {
		return nil, err
	}
	return &p, nil
}

// ParseCost decodes the cost model JSON column.
func (b *Bot) ParseCost() (*CostModel, error) {
	var c CostModel
	if b.Cost == "" {
		return &c, nil
	}
	if err := unmarshalJSON(b.Cost, &c); err != nil {
		return nil, err
	}
	return &c, nil
}

// IsSandbox reports whether the bot is a space's shared sandbox (the computer
// the space's agents work on), which the platform prices itself.
func (b *Bot) IsSandbox() bool {
	if b.Kind != KindTool || !strings.HasPrefix(b.Name, "sbx-") {
		return false
	}
	switch b.VMType {
	case VMTypeContainer, VMTypeDocker, VMTypeModal:
		return true
	}
	return false
}

// ExecutionPriced reports whether the cost model charges for execution time
// or resources (as opposed to only tokens or images).
func (c *CostModel) ExecutionPriced() bool {
	return c != nil && (c.PerMinute != 0 || c.CPUPerMin != 0 || c.MemoryPerGBMin != 0 || c.DiskPerGBMin != 0)
}

// StatusFromVMM maps a provider VM status onto the bot status.
func StatusFromVMM(s string) Status {
	switch s {
	case "running":
		return StatusRunning
	case "pending", "creating":
		return StatusPending
	case "stopped":
		return StatusStopped
	case "paused":
		return StatusPaused
	case "ended":
		return StatusEnded
	case "failed":
		return StatusFailed
	default:
		return StatusPending
	}
}

// IsAseman identifies the reserved platform orchestrator image.
func IsAseman(rec *Bot) bool { return rec != nil && rec.ImageRef == "aseman.wasm" }

// BuiltinAsemanImage is the reserved image ref marking the built-in lead agent
// (identified by this, not by its name, which an admin may change).
const BuiltinAsemanImage = "aseman.wasm"

// IsBuiltinLead reports whether the bot is the built-in lead agent.
func (b *Bot) IsBuiltinLead() bool { return b != nil && b.ImageRef == BuiltinAsemanImage }

// BuiltinChatImage is the reserved image ref marking the built-in chat assistant: the
// "@aseman" people mention in notes and personal chats (identified by this, not by name).
const BuiltinChatImage = "aseman-chat"

// IsChatAssistant reports whether the bot is the built-in chat assistant.
func (b *Bot) IsChatAssistant() bool { return b != nil && b.ImageRef == BuiltinChatImage }

// IsBuiltin reports whether the bot is a reserved platform agent (lead or chat assistant).
func (b *Bot) IsBuiltin() bool { return b.IsBuiltinLead() || b.IsChatAssistant() }

// ReasoningEfforts are the effort levels an agent can be set to; blank leaves it to the provider's default.
var ReasoningEfforts = []string{"low", "medium", "high"}

// NormalizeEffort lowercases an effort level and says whether it is one the node accepts (blank is: no setting).
func NormalizeEffort(raw string) (string, bool) {
	level := strings.ToLower(strings.TrimSpace(raw))
	if level == "" {
		return "", true
	}
	for _, known := range ReasoningEfforts {
		if level == known {
			return level, true
		}
	}
	return "", false
}

// AgentEffort is the reasoning effort in an agent's yml spec ("" when none is set).
func AgentEffort(specYML string) string {
	var spec struct {
		ReasoningEffort string `yaml:"reasoning_effort"`
	}
	if strings.TrimSpace(specYML) == "" || yaml.Unmarshal([]byte(specYML), &spec) != nil {
		return ""
	}
	return spec.ReasoningEffort
}

// AgentVoiceEffort is the reasoning effort for live voice calls in an agent's yml spec ("" when none is set).
func AgentVoiceEffort(specYML string) string {
	var spec struct {
		VoiceReasoningEffort string `yaml:"voice_reasoning_effort"`
	}
	if strings.TrimSpace(specYML) == "" || yaml.Unmarshal([]byte(specYML), &spec) != nil {
		return ""
	}
	return spec.VoiceReasoningEffort
}

// AgentVoiceBackbone is the model a live voice chat uses instead of the agent's own ("" when none is set).
func AgentVoiceBackbone(specYML string) (provider, model string) {
	var spec struct {
		Provider string `yaml:"voice_provider"`
		Model    string `yaml:"voice_model"`
	}
	if strings.TrimSpace(specYML) == "" || yaml.Unmarshal([]byte(specYML), &spec) != nil {
		return "", ""
	}
	return spec.Provider, spec.Model
}

// AgentInstructions is the instructions in an agent's yml spec ("" when none).
func AgentInstructions(specYML string) string {
	var spec struct {
		Instructions string `yaml:"instructions"`
	}
	if strings.TrimSpace(specYML) == "" || yaml.Unmarshal([]byte(specYML), &spec) != nil {
		return ""
	}
	return strings.TrimSpace(spec.Instructions)
}

// AgentBackbone extracts the LLM provider and model from an agent's yml spec.
func AgentBackbone(specYML string) (provider, model string) {
	var spec struct {
		Provider string `yaml:"provider"`
		Model    string `yaml:"model"`
	}
	if strings.TrimSpace(specYML) == "" || yaml.Unmarshal([]byte(specYML), &spec) != nil {
		return "", ""
	}
	return spec.Provider, spec.Model
}
