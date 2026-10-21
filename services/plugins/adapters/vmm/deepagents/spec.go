package deepagents

import (
	"strings"

	"github.com/aseman/aseman/pkg/errs"
	"gopkg.in/yaml.v3"
)

// Skill is a professional capability of an agent. The runtime writes each one
// into the shared sandbox as a deep agents skill (SKILL.md), so the agent loads
// its full instructions only when the skill is relevant.
type Skill struct {
	Name         string   `yaml:"name" json:"name"`
	Description  string   `yaml:"description" json:"description"`
	Instructions string   `yaml:"instructions" json:"instructions"`
	Tools        []string `yaml:"tools" json:"tools,omitempty"`
}

// Spec is an agent definition: the spec yml the bots namespace renders from
// the agent creation form. It is engine-neutral, so agents recorded on retired
// engines keep their definition.
type Spec struct {
	Name         string `yaml:"name" json:"name"`
	Description  string `yaml:"description" json:"description,omitempty"`
	Provider     string `yaml:"provider" json:"provider,omitempty"`
	Model        string `yaml:"model" json:"model,omitempty"`
	Instructions string `yaml:"instructions" json:"instructions,omitempty"`
	// Role "lead" runs the agent as the swarm's leader (the built-in aseman
	// agent); every other agent is a specialist the lead delegates to.
	Role         string   `yaml:"role" json:"role,omitempty"`
	MaxTokens    int      `yaml:"max_tokens" json:"max_tokens,omitempty"`
	MaxTurns     int      `yaml:"max_turns" json:"max_turns,omitempty"`
	AllowedTools []string `yaml:"allowed_tools" json:"allowed_tools,omitempty"`
	Skills       []Skill  `yaml:"skills" json:"skills,omitempty"`
	// InterruptOn names tools that wait for a person's approval before they
	// run (deep agents human-in-the-loop), e.g. ["execute", "file_send"].
	InterruptOn []string `yaml:"interrupt_on" json:"interrupt_on,omitempty"`
	// ReasoningEffort is passed to reasoning models.
	ReasoningEffort string `yaml:"reasoning_effort" json:"reasoning_effort,omitempty"`
	// ContextWindow drives summarization; 0 uses the model profile.
	ContextWindow int `yaml:"context_window" json:"context_window,omitempty"`
}

// ParseSpec reads an agent spec yml.
func ParseSpec(raw string) (Spec, error) {
	var spec Spec
	if strings.TrimSpace(raw) == "" {
		return spec, errs.InvalidArgument("agent spec required")
	}
	if err := yaml.Unmarshal([]byte(raw), &spec); err != nil {
		return spec, errs.InvalidArgument("invalid agent spec: " + err.Error())
	}
	if strings.TrimSpace(spec.Name) == "" {
		return spec, errs.InvalidArgument("agent spec requires a name")
	}
	return spec, nil
}

// Lead reports whether the agent leads the space's swarm.
func (s Spec) Lead() bool { return s.Role == "lead" || s.Role == "orchestrator" }
