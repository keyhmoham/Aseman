package spaces

import (
	"strings"
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

func TestDeepSeekHarnessIsTheThirdEngine(t *testing.T) {
	s, ctx := messageToolHarness(t)
	if _, err := s.SetAgentEngine(ctx, AgentEngineDeepSeek); err != nil {
		t.Fatal(err)
	}
	if engine, err := s.AgentEngine(ctx); err != nil || engine != AgentEngineDeepSeek {
		t.Fatalf("after set: %q %v", engine, err)
	}
	view, err := s.agentEngineView(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if view["llm"] != "platform" || !strings.Contains(view["status"].(string), "own memory and swarm") {
		t.Fatalf("deepseek view: %v", view)
	}
	engines, _ := view["engines"].([]string)
	if len(engines) != 3 || engines[2] != AgentEngineDeepSeek {
		t.Fatalf("engines: %v", engines)
	}
	mappings, _ := view["mappings"].(map[string][]map[string]string)
	rows := mappings[AgentEngineDeepSeek]
	how := map[string]string{}
	for _, row := range rows {
		how[row["platform"]] = row["how"]
	}
	for _, mechanism := range []string{"Memory", "Swarm", "Agent team", "Subagents", "Task handoff / dispatch",
		"Planning & workflow", "Questions to people", "Creator mode / plugin creation", "Agentic loop"} {
		if how[mechanism] == "" {
			t.Fatalf("no deepseek mapping for %s: %v", mechanism, rows)
		}
	}
	if !strings.Contains(how["Memory"], "DeepSeek Harness's own") || !strings.Contains(how["Swarm"], "DeepSeek Harness's own") {
		t.Fatalf("memory and swarm must be the harness's own: %v", how)
	}
	if len(mappings[AgentEngineOpenCode]) == 0 || mappings[AgentEngineOpenCode][0]["how"] == "" {
		t.Fatalf("opencode mapping: %v", mappings[AgentEngineOpenCode])
	}
}

func TestTheMemoryScreenFallsBackWhenNoRuntimeKeepsTheEnginesMemory(t *testing.T) {
	s, ctx := messageToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "notes", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetAgentEngine(ctx, AgentEngineDeepSeek); err != nil {
		t.Fatal(err)
	}
	_, ok, err := s.engineMemoryNotes(ctx, AgentEngineDeepSeek, sp.ID, "read", spaceNotesPath, "", "")
	if ok || err != nil {
		t.Fatalf("without a runtime the sandbox serves the notes: ok=%v err=%v", ok, err)
	}
}
