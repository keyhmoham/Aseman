package bots

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Gemini signs each tool call (extra_content.google.thought_signature) and answers 400 when the call is echoed
// back without it: what the model said is kept whole, and is what the next request carries.
func TestToolCallKeepsTheProvidersSignature(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":null,"tool_calls":[{"id":"c1","type":"function",` +
			`"function":{"name":"create_room","arguments":"{\"name\":\"Café\"}"},` +
			`"extra_content":{"google":{"thought_signature":"SIG123"}}}]}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}`))
	}))
	defer srv.Close()
	_, calls, _, _, err := callToolsOnce(context.Background(), vmm.ProviderConfig{BaseURL: srv.URL, Model: "gemini"}, map[string]any{"messages": []any{}})
	if err != nil || len(calls) != 1 {
		t.Fatalf("calls: %v %v", calls, err)
	}
	echo, err := json.Marshal(calls)
	if err != nil || !strings.Contains(string(echo), `"thought_signature":"SIG123"`) {
		t.Fatalf("the echoed call lost its signature: %s (%v)", echo, err)
	}
}

func TestProviderRefusalCarriesWhatItSaid(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(400)
		_, _ = w.Write([]byte(`{"error":{"message":"bad tool"}}`))
	}))
	defer srv.Close()
	_, _, _, _, err := callToolsOnce(context.Background(), vmm.ProviderConfig{BaseURL: srv.URL, Model: "m"}, map[string]any{"messages": []any{}})
	if err == nil || !strings.Contains(err.Error(), "bad tool") {
		t.Fatalf("error: %v", err)
	}
}
