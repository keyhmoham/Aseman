package harness

import (
	"encoding/json"
	"testing"
)

func TestFillThoughtSignaturesKeepsRealOnesAndFillsMissing(t *testing.T) {
	var body map[string]any
	_ = json.Unmarshal([]byte(`{"messages":[
		{"role":"user","content":"hi"},
		{"role":"assistant","tool_calls":[
			{"id":"a","type":"function","function":{"name":"ls","arguments":"{}"}},
			{"id":"b","type":"function","extra_content":{"google":{"thought_signature":"real"}},"function":{"name":"ls","arguments":"{}"}}]}]}`), &body)
	fillThoughtSignatures(body)
	calls := body["messages"].([]any)[1].(map[string]any)["tool_calls"].([]any)
	sig := func(i int) string {
		return calls[i].(map[string]any)["extra_content"].(map[string]any)["google"].(map[string]any)["thought_signature"].(string)
	}
	if sig(0) != skipThoughtSignature || sig(1) != "real" {
		t.Fatalf("signatures = %q, %q", sig(0), sig(1))
	}
}
