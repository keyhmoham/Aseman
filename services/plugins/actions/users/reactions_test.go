package users

import (
	"testing"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
)

func TestReactingToAMessage(t *testing.T) {
	f := dmHarness(t)
	f.send(f.alice, f.bob, "ship it")
	peerA, peerB := map[string]any{"peer": f.bob.ID.String()}, map[string]any{"peer": f.alice.ID.String()}
	id := firstMessage(f.must("dm_list", f.alice, peerA))["id"].(string)

	f.must("dm_react", f.bob, map[string]any{"id": id, "emoji": "👍"})
	f.must("dm_react", f.alice, map[string]any{"id": id, "emoji": "❤️"})
	// A second emoji from the same person replaces the first.
	out := f.must("dm_react", f.bob, map[string]any{"id": id, "emoji": "🔥"})
	if rs := out["reactions"].([]any); len(rs) != 2 {
		t.Fatalf("reactions = %v", rs)
	}
	for _, c := range []struct {
		who  api.Caller
		peer map[string]any
	}{{f.alice, peerA}, {f.bob, peerB}} {
		rs, _ := firstMessage(f.must("dm_list", c.who, c.peer))["reactions"].([]any)
		if len(rs) != 2 {
			t.Fatalf("list shows %v", rs)
		}
	}

	// Taking it off removes only the caller's.
	f.must("dm_react", f.bob, map[string]any{"id": id, "emoji": ""})
	rs := firstMessage(f.must("dm_list", f.alice, peerA))["reactions"].([]any)
	if len(rs) != 1 || rs[0].(map[string]any)["emoji"] != "❤️" {
		t.Fatalf("after removal %v", rs)
	}
	if _, err := f.call("dm_react", f.bob, map[string]any{"id": id, "emoji": "hello"}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("text accepted as emoji: %v", err)
	}
}
