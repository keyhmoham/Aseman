package dto

import (
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
)

// ComputerTimeDesc is the description of the one charge a project's computer
// takes: the time it was awake. Commands run on it are not billed one by one.
const ComputerTimeDesc = "computer time"

type SkillConfig struct {
	Name         string   `json:"name"`
	Description  string   `json:"description"`
	Instructions string   `json:"instructions"`
	Tools        []string `json:"tools"`
}

type CreateBotRequest struct {
	Name        string              `json:"name"`
	Kind        bot.Kind            `json:"kind,omitempty"` // agent | tool
	VMType      bot.VMType          `json:"vm_type"`
	ImageRef    string              `json:"image_ref"`
	SpecYML     string              `json:"spec_yml"`
	Resources   bot.ResourceProfile `json:"resources"`
	Cost        bot.CostModel       `json:"cost"`
	Env         map[string]string   `json:"env,omitempty"`
	Args        []string            `json:"args,omitempty"`
	Frontend    string              `json:"frontend,omitempty"`     // elpian app bundle
	FrontendRef string              `json:"frontend_ref,omitempty"` // ref to a stored bundle
	// Entities carries arbitrary runtime artifacts keyed by contract keys
	// (backend, spec, frontend, static/<name>, ...). New entity types can be
	// added without schema changes.
	Entities map[string]string `json:"entities,omitempty"`

	// Structured configuration for the UI creation forms. When present, the
	// service validates it per kind and renders the VM spec server-side.
	Description  string        `json:"description,omitempty"`
	Instructions string        `json:"instructions,omitempty"` // agent system prompt
	Provider     string        `json:"provider,omitempty"`     // agent LLM provider (admin-configured)
	Model        string        `json:"model,omitempty"`        // agent LLM model
	MaxTokens    int           `json:"max_tokens,omitempty"`
	AllowedTools []string      `json:"allowed_tools,omitempty"`
	MaxTurns     int           `json:"max_turns,omitempty"`
	Skills       []SkillConfig `json:"skills,omitempty"`
	Module       string        `json:"module,omitempty"`     // app wasm module
	WidgetDSL    string        `json:"widget_dsl,omitempty"` // app desk-widget DSL

	// Service runs the VM as a service other parts of the node reach by name
	// (a managed tool backend). Set only by namespaces of this node: the
	// bots.bot_create action clears it, since a name on the node's network is
	// not something a user may claim.
	Service *ServiceSpec `json:"service,omitempty"`
}

// ServiceSpec names a service VM on a docker network.
type ServiceSpec struct {
	// ID is the VM's stable id and its alias on Network.
	ID      string `json:"id"`
	Network string `json:"network,omitempty"`
	Port    int    `json:"port"`
}
