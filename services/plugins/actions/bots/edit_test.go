package bots

import (
	"testing"

	"github.com/aseman/aseman/plugins/adapters/vmm/deepagents"

	"gopkg.in/yaml.v3"
)

func TestAgentConfigReadsTheFormBack(t *testing.T) {
	spec, err := renderAgentSpec(CreateBotRequest{
		Name: "quant", Description: "Finds trades", Instructions: "Analyze markets.\nBe careful.",
		Provider: "p1", Model: "gpt-5.6", MaxTurns: 5, MaxTokens: 4000,
		Skills: []SkillConfig{{Name: "Research", Description: "Agent capability: Research"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	got := agentConfig(spec)
	if got["description"] != "Finds trades" || got["instructions"] != "Analyze markets.\nBe careful." ||
		got["provider"] != "p1" || got["model"] != "gpt-5.6" || got["max_turns"] != 5 || got["max_tokens"] != 4000 {
		t.Fatalf("form fields not read back: %+v", got)
	}
	skills := got["skills"].([]SkillConfig)
	if len(skills) != 1 || skills[0].Name != "Research" {
		t.Fatalf("skills not read back: %+v", skills)
	}
}

// An edited spec, as bot_edit writes it, still parses as the agent runtime's spec.
func TestEditedSpecStillParses(t *testing.T) {
	spec := map[string]any{"name": "quant", "instructions": "Trade.", "max_turns": 5, "description": "old"}
	setOrDrop(spec, "max_turns", 12, true)
	setOrDrop(spec, "description", "", false)
	spec["skills"] = skillsSpec([]SkillConfig{{Name: "scan", Tools: []string{"execute"}}})
	raw, err := yaml.Marshal(spec)
	if err != nil {
		t.Fatal(err)
	}
	var agent deepagents.Spec
	if err := yaml.Unmarshal(raw, &agent); err != nil {
		t.Fatalf("edited spec must parse: %v\n%s", err, raw)
	}
	if agent.MaxTurns != 12 || len(agent.Skills) != 1 || agent.Skills[0].Tools[0] != "execute" {
		t.Fatalf("edit not applied: %+v", agent)
	}
	if _, ok := spec["description"]; ok {
		t.Fatal("a cleared description must leave the spec")
	}
	if got := agentConfig(""); len(got["skills"].([]SkillConfig)) != 0 {
		t.Fatal("an empty spec has no skills")
	}
}
