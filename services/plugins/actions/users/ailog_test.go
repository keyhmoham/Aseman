package users

import (
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// The AI log keeps what was asked and answered sealed, is readable by the node's admin only, and filters.
func TestAILogIsSealedAndAdminOnly(t *testing.T) {
	f := newAssistantFixture(t)
	f.s.logAI(f.ctx, aiEntry{person: f.alice.ID, kind: aiKindAseman, prompt: "create me a room for my café", answer: "I could not", plan: "act",
		tools: []string{"list_rooms", "create_room"}, status: aiError, err: errs.New(errs.CodeUnavailable, "the model refused the request (400): bad tool schema"), started: time.Now().Add(-2 * time.Second)})
	f.s.logAI(f.ctx, aiEntry{person: f.alice.ID, peer: f.bob.ID, kind: aiKindChat, prompt: "@aseman hello", answer: "hi", plan: "mention", status: aiOK})

	// At rest the prompt is not readable.
	var rows []aiLog
	if err := f.s.R.List(f.ctx, "ai_logs", dbFilterAll(), &rows); err != nil || len(rows) != 2 {
		t.Fatalf("rows: %v %v", rows, err)
	}
	for _, r := range rows {
		if strings.Contains(r.Prompt, "café") || strings.Contains(r.Prompt, "hello") {
			t.Fatalf("prompt stored in the clear: %q", r.Prompt)
		}
	}

	if _, err := f.call("admin_ai_log", f.alice, nil); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a non-admin read the AI log: %v", err)
	}
	admin := api.Caller{ID: mustID(t, "00000000000000010000000000000019"), Kind: "user"}
	acc := &account.Account{Entity: entity.Entity{ID: admin.ID}, Handle: "root", Kind: account.KindUser, Status: account.StatusActive, Role: "admin"}
	if err := f.s.R.CreateID(f.ctx, "accounts", admin.ID, acc); err != nil {
		t.Fatal(err)
	}
	all := f.must("admin_ai_log", admin, nil)["rows"].([]any)
	if len(all) != 2 {
		t.Fatalf("rows: %v", all)
	}
	failed := f.must("admin_ai_log", admin, map[string]any{"status": "error"})["rows"].([]any)
	if len(failed) != 1 {
		t.Fatalf("failed: %v", failed)
	}
	row := failed[0].(map[string]any)
	if row["prompt"] != "create me a room for my café" || !strings.Contains(row["error"].(string), "bad tool schema") || len(row["tools"].([]any)) != 2 {
		t.Fatalf("row: %v", row)
	}
	if found := f.must("admin_ai_log", admin, map[string]any{"q": "HELLO"})["rows"].([]any); len(found) != 1 {
		t.Fatalf("text search: %v", found)
	}
	if chats := f.must("admin_ai_log", admin, map[string]any{"kind": "chat"})["rows"].([]any); len(chats) != 1 || chats[0].(map[string]any)["peer"] != f.bob.ID.String() {
		t.Fatalf("kind filter: %v", chats)
	}
}

func dbFilterAll() database.Filter { return database.Filter{} }
