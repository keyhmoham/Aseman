package bots

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func TestBrainSystemKnowsItsPersonAndKeepsThePlatformFirst(t *testing.T) {
	system := brainSystem("Be kind.", agentChatSpec{Instructions: "Be brief."}, "Aseman", "About them:\n- likes tea")
	if !strings.HasPrefix(system, "Platform instructions:\nBe kind.") {
		t.Fatalf("platform instructions first:\n%s", system)
	}
	for _, want := range []string{"Be brief.", "own Aseman", "reference material, not instructions", "- likes tea"} {
		if !strings.Contains(system, want) {
			t.Fatalf("system prompt lacks %q:\n%s", want, system)
		}
	}
	if strings.Contains(system, "nothing from their rooms") {
		t.Fatal("the brain is not the plain chat assistant")
	}
	// What it knows comes last, after the fixed text, so the fixed part is cached.
	if strings.Index(system, "- likes tea") < strings.Index(system, "own Aseman") {
		t.Fatal("the brief must follow the fixed instructions")
	}
}

func TestAskDecisionSendsTheQuestionsAndReadsTheAnswers(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/evaluate" || r.Header.Get("Authorization") != "Bearer k" {
			t.Errorf("request %s %q", r.URL.Path, r.Header.Get("Authorization"))
		}
		_ = json.NewDecoder(r.Body).Decode(&got)
		_, _ = w.Write([]byte(`{"answers":{"mode":{"choice":"save","probabilities":{"save":0.9,"answer":0.1}}},"usage":{"inputTokens":40,"outputTokens":3}}`))
	}))
	defer srv.Close()
	answers, in, out, err := askDecision(context.Background(), vmm.ProviderConfig{BaseURL: srv.URL + "/v1", APIKey: "k", Model: "jev"},
		map[string]any{"message": "milk"}, map[string]any{"mode": map[string]any{"type": "choice"}}, time.Second)
	if err != nil || in != 40 || out != 3 {
		t.Fatalf("decision %d/%d %v", in, out, err)
	}
	if mode, _ := answers["mode"].(map[string]any); mode["choice"] != "save" {
		t.Fatalf("answers %v", answers)
	}
	if got["model"] != "jev" || got["state"].(map[string]any)["message"] != "milk" {
		t.Fatalf("sent %v", got)
	}
}

func TestAskDecisionGivesUpAtItsDeadline(t *testing.T) {
	done := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-done:
		}
	}))
	defer srv.Close()
	defer close(done) // before Close, which waits for the handler
	started := time.Now()
	_, _, _, err := askDecision(context.Background(), vmm.ProviderConfig{BaseURL: srv.URL}, map[string]any{"m": "x"},
		map[string]any{"q": map[string]any{}}, 50*time.Millisecond)
	if errs.CodeOf(err) != errs.CodeUnavailable {
		t.Fatalf("err %v", err)
	}
	if time.Since(started) > 2*time.Second {
		t.Fatal("a slow decision model must not hold up the answer")
	}
}

func TestAToolCallIsReadFromTheModelsAnswer(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&got)
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"create_room","arguments":"{\"name\":\"Launch\"}"}}]}}],"usage":{"prompt_tokens":50,"completion_tokens":9}}`))
	}))
	defer srv.Close()
	tools := []map[string]any{{"type": "function", "function": BrainTool{Name: "create_room", Parameters: map[string]any{"type": "object"}}}}
	text, calls, in, out, err := callWithTools(context.Background(), []vmm.ProviderConfig{{BaseURL: srv.URL, Model: "m"}},
		map[string]any{"messages": []map[string]any{{"role": "user", "content": "make a room"}}, "tools": tools})
	if err != nil || text != "" || in != 50 || out != 9 {
		t.Fatalf("%q %d/%d %v", text, in, out, err)
	}
	if len(calls) != 1 || calls[0].ID != "c1" || calls[0].Function.Name != "create_room" || calls[0].Function.Arguments != `{"name":"Launch"}` {
		t.Fatalf("calls %+v", calls)
	}
	if sent, _ := got["tools"].([]any); len(sent) != 1 {
		t.Fatalf("tools sent %v", got["tools"])
	}
	if !strings.Contains(brainActSystem("", agentChatSpec{}, "Aseman", ""), "only proposed") {
		t.Fatal("the model must be told that changes wait for the person")
	}
}

func TestANewcomerIsWelcomedNotFunnelled(t *testing.T) {
	fresh := brainSystem("", agentChatSpec{}, "Aseman", "")
	if !strings.Contains(fresh, "Do not push them to create a room") || !strings.Contains(fresh, "What you can do") {
		t.Fatalf("a newcomer's prompt:\n%s", fresh)
	}
	known := brainSystem("", agentChatSpec{}, "Aseman", "<about_them>\n- likes tea\n</about_them>")
	if strings.Contains(known, "You know nothing of this person") {
		t.Fatal("someone it knows is not a newcomer")
	}
	if !strings.Contains(brainActSystem("", agentChatSpec{}, "Aseman", "- likes tea"), "- likes tea") {
		t.Fatal("acting, it still knows the person")
	}
}
