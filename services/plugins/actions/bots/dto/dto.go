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
	Kind        bot.Kind            `json:"kind,omitempty"` // agent | miniapp | tool
	VMType      bot.VMType          `json:"vm_type"`
	ImageRef    string              `json:"image_ref"`
	SpecYML     string              `json:"spec_yml"`
	Resources   bot.ResourceProfile `json:"resources"`
	Cost        bot.CostModel       `json:"cost"`
	Env         map[string]string   `json:"env,omitempty"`
	Args        []string            `json:"args,omitempty"`
	Frontend    string              `json:"frontend,omitempty"`     // elpian miniapp bundle
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
	Module       string        `json:"module,omitempty"`     // miniapp/tool wasm module
	WidgetDSL    string        `json:"widget_dsl,omitempty"` // miniapp desk-widget DSL
}
