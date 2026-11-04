package harness

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func TestFreshGatewayOnlyReadsCurrentHandoffRepliesAndAttachments(t *testing.T) {
	s := &session{base: vmm.WithExecution(context.Background(), vmm.Execution{NoMemory: true}),
		sentMessages: map[string]bool{"current-task": true}, attachments: map[string]bool{"current-file": true}}
	for _, tc := range []struct {
		name, body string
		allowed    bool
	}{
		{"spaces.message_list", `{}`, false},
		{"spaces.message_list", `{"reply_to":"old-task"}`, false},
		{"spaces.message_list", `{"reply_to":"current-task"}`, true},
		{"spaces.message_search", `{}`, false},
		{"users.dm_list", `{}`, false},
		{"spaces.file_list", `{}`, false},
		{"spaces.room_get", `{}`, false},
		{"spaces.file_get", `{"file":"old-file"}`, false},
		{"spaces.file_get", `{"file":"current-file"}`, true},
		{"spaces.ask", `{"tool":"file_read","args":{"file_id":"current-file"}}`, true},
		{"spaces.ask", `{"tool":"file_read","args":{"url":"/v1/files/current-file/content"}}`, true},
		{"spaces.ask", `{"tool":"file_read","args":{"file_id":"old-file"}}`, false},
		{"spaces.ask", `{"tool":"file_read","args":{"path":"/workspace/AGENTS.md"}}`, false},
		{"spaces.message_send", `{}`, true},
	} {
		if err := s.checkRequestMode(tc.name, json.RawMessage(tc.body)); (err == nil) != tc.allowed {
			t.Errorf("%s %s: %v", tc.name, tc.body, err)
		}
	}
	s.base = context.Background()
	if err := s.checkRequestMode("spaces.message_list", json.RawMessage(`{}`)); err != nil {
		t.Fatal("ordinary history blocked", err)
	}
}
