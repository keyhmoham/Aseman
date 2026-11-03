package deepagents

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	network "github.com/aseman/aseman/plugins/adapters/network/ports"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// DeepSeek Harness runs on the agents' platform models and brings its own
// memory: the turn carries the model's window, the metered LLM handle, the
// timeline and Code Mode, but no OpenViking or decision payloads.
func TestADeepSeekTurnRunsOnPlatformModelsWithItsOwnMemory(t *testing.T) {
	a, _, _ := newTestAdapter(t)
	a.platform = fakePlatform{
		provider:        vmm.ProviderConfig{Model: "m1", ContextWindow: 200000},
		decision:        &vmm.ProviderConfig{Model: "decide"},
		memoryChat:      &vmm.ProviderConfig{Model: "memory-chat"},
		memoryEmbedding: &vmm.ProviderConfig{Model: "memory-embed"},
		timeline:        func(string, []byte) ([]byte, error) { return nil, nil },
		agentEngine:     "deepseek",
	}
	turn := testTurn()
	turn.Agent.AccountID = mustID(t)
	s, req, err := a.open(context.Background(), onlyVM(t, a), turn)
	if err != nil {
		t.Fatal(err)
	}
	defer a.close(s)
	if req.AgentEngine != "deepseek" {
		t.Fatalf("agent_engine = %q", req.AgentEngine)
	}
	if req.Agent.ContextWindow != 200000 {
		t.Fatalf("the model's window was not resolved: %+v", req.Agent)
	}
	if req.Decision != nil || req.Memory.Recall || req.Memory.Learn {
		t.Fatalf("the platform's memory or decisions crossed a DeepSeek Harness turn: %+v", req)
	}
	if !req.Timeline || !req.CodeMode {
		t.Fatalf("timeline and Code Mode must reach the harness: %+v", req)
	}
	if llm := vmm.TurnLLMFrom(s.base); llm.Token != s.token || !strings.HasSuffix(llm.BaseURL, "/llm") {
		t.Fatalf("the metered LLM handle is missing: %+v", llm)
	}
}

func TestAnUnknownEngineRunsOnDeepAgents(t *testing.T) {
	a, rt, _ := newTestAdapter(t)
	a.platform = fakePlatform{provider: vmm.ProviderConfig{Model: "m1"}, agentEngine: "langchain"}
	turn := testTurn()
	turn.Agent.AccountID = mustID(t)
	if _, err := a.Prompt(context.Background(), onlyVM(t, a), turn); err != nil {
		t.Fatal(err)
	}
	if got := rt.turns[0].AgentEngine; got != "deepagents" {
		t.Fatalf("agent_engine = %q", got)
	}
}

// A personal session serves the assistant's model on /llm when it has one,
// and nothing when it has none (OpenCode brings its own).
func TestAPersonalSessionServesOnlyItsOwnModel(t *testing.T) {
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"hi"}}],"usage":{"prompt_tokens":11,"completion_tokens":7}}`))
	}))
	t.Cleanup(provider.Close)
	a, _, _ := newTestAdapter(t)
	a.platform = fakePlatform{provider: vmm.ProviderConfig{BaseURL: provider.URL, Model: "m1"}}
	person := mustIDValue(t)
	s, err := a.openPersonal(context.Background(), person)
	if err != nil {
		t.Fatal(err)
	}
	ask := func() *network.Response {
		resp, err := a.serveChat(context.Background(), &network.Request{
			Header: map[string]string{"Authorization": "Bearer " + s.token},
			Body:   []byte(`{"model":"m1","messages":[{"role":"user","content":"hi"}]}`),
		})
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}
	if resp := ask(); resp.Status != http.StatusForbidden {
		t.Fatalf("a session with no model got %d %s", resp.Status, resp.Body)
	}
	s.chat = &Spec{Name: "Aseman", Model: "m1"}
	if resp := ask(); resp.Status != http.StatusOK {
		t.Fatalf("got %d %s", resp.Status, resp.Body)
	}
	if s.tokIn != 11 || s.tokOut != 7 {
		t.Fatalf("not metered on the session: %d / %d", s.tokIn, s.tokOut)
	}
	models, _ := a.serveModels(context.Background(), &network.Request{Header: map[string]string{"Authorization": "Bearer " + s.token}})
	if models.Status != http.StatusOK || !strings.Contains(string(models.Body), `"m1"`) {
		t.Fatalf("models: %d %s", models.Status, models.Body)
	}
}

func TestPersonalChatOnDeepSeekReportsWhatItUsed(t *testing.T) {
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"hi"}}],"usage":{"prompt_tokens":100,"completion_tokens":20}}`))
	}))
	t.Cleanup(provider.Close)
	a, rt, _ := newTestAdapter(t)
	a.platform = fakePlatform{provider: vmm.ProviderConfig{BaseURL: provider.URL, Model: "m1"}, agentEngine: "deepseek"}
	rt.onChat = func(body map[string]any) {
		// The harness calls its model on the person's session while it answers.
		token, _ := body["token"].(string)
		resp, _ := a.serveChat(context.Background(), &network.Request{
			Header: map[string]string{"Authorization": "Bearer " + token},
			Body:   []byte(`{"model":"m1","messages":[{"role":"user","content":"hi"}]}`),
		})
		if resp == nil || resp.Status != http.StatusOK {
			t.Errorf("the harness could not reach its model: %+v", resp)
		}
	}
	var used vmm.ChatUsage
	reply, err := a.PersonalChat(context.Background(), vmm.PersonalChat{
		System: "be brief", Messages: []vmm.ChatMessage{{Role: "user", Content: "hi"}},
		PersonID: mustID(t), Provider: "prov", Model: "m1", Usage: &used,
	})
	if err != nil || reply != "hello from the engine" {
		t.Fatalf("reply %q %v", reply, err)
	}
	body := rt.chats[0]
	if body["agent_engine"] != "deepseek" || body["token"] == "" || body["gateway"] != "http://node:8080"+gatewayPrefix {
		t.Fatalf("chat body: %v", body)
	}
	if used.TokensIn != 100 || used.TokensOut != 20 {
		t.Fatalf("usage: %+v", used)
	}
	if a.byToken(body["token"].(string)) != nil {
		t.Fatal("the person's session outlived the chat")
	}
}

func TestEngineMemoryIsTheRuntimes(t *testing.T) {
	a, rt, _ := newTestAdapter(t)
	rt.memory = map[string]any{"engine": "deepseek", "space_notes": "- ships on fridays", "agents": []string{"bot-1"},
		"agent": "bot-1", "notes": "- ann likes tabs", "journal": []map[string]string{{"day": "2026-11-03", "text": "Asked: x"}}}
	view, err := a.EngineMemoryRead(context.Background(), "deepseek", "space-1", "bot-1")
	if err != nil {
		t.Fatal(err)
	}
	if view.SpaceNotes != "- ships on fridays" || view.Notes != "- ann likes tabs" || view.Journal[0].Day != "2026-11-03" {
		t.Fatalf("view: %+v", view)
	}
	if rt.memoryQuery != "agent=bot-1&space=space-1" {
		t.Fatalf("query: %s", rt.memoryQuery)
	}
	if err := a.EngineMemoryWrite(context.Background(), "deepseek", "space-1", "", "# Space notes"); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(rt.memoryWrites[0])
	if string(raw) != `{"agent":"","content":"# Space notes","space":"space-1"}` {
		t.Fatalf("write: %s", raw)
	}
	if _, err := a.EngineMemoryRead(context.Background(), "opencode", "space-1", ""); err == nil {
		t.Fatal("opencode keeps no memory of its own")
	}
}

func mustIDValue(t *testing.T) identity.ID {
	t.Helper()
	id, err := identity.Parse(mustID(t))
	if err != nil {
		t.Fatal(err)
	}
	return id
}
