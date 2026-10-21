package bots

import (
	"strings"
	"testing"

	"github.com/aseman/aseman/plugins/adapters/vmm/deepagents"

	"gopkg.in/yaml.v3"
)

func TestRenderAgentSpec(t *testing.T) {
	spec, err := renderAgentSpec(CreateBotRequest{
		Name:         "quant",
		Instructions: "Analyze markets.\nBe careful.",
		Model:        "gpt-5.6",
		MaxTurns:     5,
		Skills: []SkillConfig{{
			Name: "scan", Description: "scan markets", Tools: []string{"execute"},
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	var agent deepagents.Spec
	if err := yaml.Unmarshal([]byte(spec), &agent); err != nil {
		t.Fatalf("spec must parse as agent yml: %v\n%s", err, spec)
	}
	if agent.Name != "quant" || agent.Model != "gpt-5.6" || agent.MaxTurns != 5 {
		t.Fatalf("bad spec values: %+v", agent)
	}
	if !strings.Contains(agent.Instructions, "Analyze markets") || !strings.Contains(agent.Instructions, "Be careful") {
		t.Fatalf("instructions not preserved: %q", agent.Instructions)
	}
	if len(agent.Skills) != 1 || agent.Skills[0].Name != "scan" || len(agent.Skills[0].Tools) != 1 {
		t.Fatalf("skills not preserved: %+v", agent.Skills)
	}
}

func TestRenderAgentSpecRequiresInstructions(t *testing.T) {
	if _, err := renderAgentSpec(CreateBotRequest{Name: "x"}); err == nil {
		t.Fatal("expected error when no instructions")
	}
}
