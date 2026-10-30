package spaces

import (
	"testing"

	"github.com/aseman/aseman/pkg/errs"
)

func TestAgentEngineDefaultsToDeepAgentsAndSwitchesImmediately(t *testing.T) {
	s, ctx := messageToolHarness(t)
	engine, err := s.AgentEngine(ctx)
	if err != nil || engine != AgentEngineDeepAgents {
		t.Fatalf("default engine: %q %v", engine, err)
	}
	view, err := s.agentEngineView(ctx)
	if err != nil || view["engine"] != AgentEngineDeepAgents || view["llm"] != "platform" || view["active"] != true {
		t.Fatalf("default view: %v %v", view, err)
	}
	if _, err := s.SetAgentEngine(ctx, AgentEngineOpenCode); err != nil {
		t.Fatal(err)
	}
	if engine, err = s.AgentEngine(ctx); err != nil || engine != AgentEngineOpenCode {
		t.Fatalf("after set: %q %v", engine, err)
	}
	view, _ = s.agentEngineView(ctx)
	if view["llm"] != "opencode-free" || view["programmer"] != "spaces.opencode_get" {
		t.Fatalf("opencode view: %v", view)
	}
	mapping, _ := view["mapping"].([]map[string]string)
	if len(mapping) < 5 {
		t.Fatalf("mapping: %v", view["mapping"])
	}
	if _, err := s.SetAgentEngine(ctx, AgentEngineDeepAgents); err != nil {
		t.Fatal(err)
	}
	if engine, _ = s.AgentEngine(ctx); engine != AgentEngineDeepAgents {
		t.Fatalf("switched back: %s", engine)
	}
}

func TestAgentEngineRejectsAnUnknownRuntime(t *testing.T) {
	s, ctx := messageToolHarness(t)
	_, err := s.SetAgentEngine(ctx, "langchain")
	if errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("unknown engine: %v", err)
	}
	if engine, _ := s.AgentEngine(ctx); engine != AgentEngineDeepAgents {
		t.Fatalf("unchanged: %s", engine)
	}
}

func TestAgentEngineDoesNotTouchTheProgrammerSwitch(t *testing.T) {
	s, ctx := messageToolHarness(t)
	if _, err := s.SetAgentEngine(ctx, AgentEngineOpenCode); err != nil {
		t.Fatal(err)
	}
	on, err := s.OpenCodeEnabled(ctx)
	if err != nil || on {
		t.Fatalf("programmer OpenCode must stay off: %v %v", on, err)
	}
	if _, err := s.SetOpenCode(ctx, true); err != nil {
		t.Fatal(err)
	}
	engine, err := s.AgentEngine(ctx)
	if err != nil || engine != AgentEngineOpenCode {
		t.Fatalf("programmer switch changed the engine: %q %v", engine, err)
	}
	if on, _ = s.OpenCodeEnabled(ctx); !on {
		t.Fatal("programmer switch must still be on")
	}
}
