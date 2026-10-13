package timeline

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/memory"
	dbmodel "github.com/tradera/tradera/plugins/testutil"
)

// TestAgainstUtopia runs the feeds and the agents' MCP against a real Utopia
// (the stack's "timeline" service): TRADERA_TEST_UTOPIA=http://host:1516.
func TestAgainstUtopia(t *testing.T) {
	url := getenv("TRADERA_TEST_UTOPIA")
	if url == "" {
		t.Skip("set TRADERA_TEST_UTOPIA to run the Utopia integration test")
	}
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range append(dbmodel.Models(), Models()...) {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv(EnvURL, url)
	if getenv(EnvPassword) == "" {
		t.Setenv(EnvPassword, "integration-password")
	}
	s := NewService(fakeKernel{}, &repo.Repo{DB: db}, logger.Global())
	seed(t, s, ctx, time.Now().UTC())
	if err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}

	list, err := s.MCP(ctx, spaceA, []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(list), `"timeline"`) || strings.Contains(string(list), `"remember"`) {
		t.Fatalf("tools/list = %s", list)
	}
	call := func(space, tool string, args map[string]any) string {
		body, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 2, "method": "tools/call",
			"params": map[string]any{"name": tool, "arguments": args}})
		out, err := s.MCP(ctx, space, body)
		if err != nil {
			t.Fatal(err)
		}
		return string(out)
	}
	// Utopia reads the pushed statements in the background.
	var history string
	for deadline := time.Now().Add(90 * time.Second); time.Now().Before(deadline); time.Sleep(2 * time.Second) {
		history = call(spaceA, "timeline", map[string]any{"entity": "Coder (#000c0d)"})
		if strings.Contains(history, "sandbox_exec") && strings.Contains(history, "message_send") {
			break
		}
	}
	t.Logf("timeline of Coder:\n%s", history)
	if !strings.Contains(history, "sandbox_exec") {
		t.Fatalf("the agent's tool runs are not on its timeline: %s", history)
	}
	changes := call(spaceA, "changes", map[string]any{"since": time.Now().UTC().Add(-time.Hour).Format(time.RFC3339)})
	t.Logf("changes:\n%s", changes)
	if !strings.Contains(changes, "asked for") {
		t.Fatalf("the request is not among the changes: %s", changes)
	}
	// Another space's timeline knows nothing of it.
	if other := call(spaceB, "timeline", map[string]any{"entity": "Coder (#000c0d)"}); strings.Contains(other, "sandbox_exec") {
		t.Fatalf("space B sees space A's timeline: %s", other)
	}
}

func getenv(k string) string { return strings.TrimSpace(os.Getenv(k)) }
