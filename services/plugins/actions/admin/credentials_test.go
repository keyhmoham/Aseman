package admin

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestTableCredentialsRedacted(t *testing.T) {
	input := []map[string]any{{"name": "provider", "api_key": "private-api-key", "password_hash": "private-hash", "metadata": json.RawMessage(`{"credentials":{"client_secret":"private-secret","refresh_token":"private-token"},"name":"kept"}`)}}
	out := redactCredentials(input)
	raw, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "private-") || !strings.Contains(string(raw), "kept") || !strings.Contains(string(raw), "provider") {
		t.Fatalf("bad redaction: %s", raw)
	}
	if input[0]["api_key"] != "private-api-key" {
		t.Fatal("redaction mutated source")
	}
}
