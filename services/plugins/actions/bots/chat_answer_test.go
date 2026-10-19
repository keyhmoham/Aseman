package bots

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	vmm "github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

func TestChatAnswerCallsTheModelWithTheAgentsInstructions(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" || r.Header.Get("Authorization") != "Bearer k" {
			t.Errorf("request %s %q", r.URL.Path, r.Header.Get("Authorization"))
		}
		_ = json.NewDecoder(r.Body).Decode(&got)
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"  Tidied.  "}}],"usage":{"prompt_tokens":120,"completion_tokens":8}}`))
	}))
	defer srv.Close()
	system := chatAnswerSystem("Be kind.", agentChatSpec{Description: "Edits prose.", Instructions: "Keep the author's voice."}, "Writer")
	for _, want := range []string{"Be kind.", "You are Writer. Edits prose.", "Keep the author's voice.", "no tools"} {
		if !strings.Contains(system, want) {
			t.Fatalf("system prompt lacks %q:\n%s", want, system)
		}
	}
	text, in, out, err := callChat(context.Background(), vmm.ProviderConfig{BaseURL: srv.URL + "/v1/", APIKey: "k", Model: "m"},
		map[string]any{"messages": []map[string]any{{"role": "system", "content": system}, {"role": "user", "content": "tidy this"}}})
	if err != nil || text != "Tidied." || in != 120 || out != 8 {
		t.Fatalf("answer %q %d/%d %v", text, in, out, err)
	}
	if got["model"] != "m" {
		t.Fatalf("model %v", got["model"])
	}
}

func TestChatAnswerReadsTextParts(t *testing.T) {
	if got := contentText([]any{map[string]any{"type": "text", "text": "a"}, map[string]any{"type": "text", "text": "b"}}); got != "ab" {
		t.Fatal(got)
	}
}
