package users

import (
	"testing"

	"github.com/aseman/aseman/pkg/errs"
)

func TestNotificationChoices(t *testing.T) {
	f := dmHarness(t)
	alice := f.alice.ID
	room := "00000000000000010000000000000a01"
	chat := f.bob.ID.String()
	other := "00000000000000010000000000000a02"

	rooms := PushNote{Kind: "message", Space: room}
	dm := PushNote{Kind: "dm", Peer: chat}
	call := PushNote{Kind: "call", Peer: chat}
	invite := PushNote{Kind: "invite", Space: room}
	for _, n := range []PushNote{rooms, dm, call, invite, {Kind: "something-new"}} {
		if !f.s.wantsPush(f.ctx, alice, n) {
			t.Fatalf("nothing was turned off yet, but %+v is held back", n)
		}
	}

	// Everything starts on.
	got := f.must("notify_prefs", f.alice, nil)
	cats := got["categories"].(map[string]any)
	if len(cats) != 4 || cats["rooms"] != true || cats["calls"] != true || len(got["muted_spaces"].([]any)) != 0 {
		t.Fatalf("defaults = %v", got)
	}

	// A kind turned off stops only that kind.
	f.must("notify_set", f.alice, map[string]any{"category": "chats", "enabled": false})
	if f.s.wantsPush(f.ctx, alice, dm) || !f.s.wantsPush(f.ctx, alice, rooms) || !f.s.wantsPush(f.ctx, alice, call) {
		t.Fatal("turning chats off must stop chat messages and nothing else")
	}
	// ...for that person only.
	if !f.s.wantsPush(f.ctx, f.bob.ID, dm) {
		t.Fatal("alice's choice reached bob")
	}
	f.must("notify_set", f.alice, map[string]any{"category": "chats", "enabled": true})
	if !f.s.wantsPush(f.ctx, alice, dm) {
		t.Fatal("turning chats back on did not")
	}
	if _, err := f.call("notify_set", f.alice, map[string]any{"category": "everything", "enabled": false}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("unknown category: %v", err)
	}

	// A muted room is quiet for its messages, not for invitations or other rooms.
	f.must("notify_mute", f.alice, map[string]any{"kind": "space", "id": room, "muted": true})
	if f.s.wantsPush(f.ctx, alice, rooms) {
		t.Fatal("a message from a muted room got through")
	}
	if !f.s.wantsPush(f.ctx, alice, PushNote{Kind: "message", Space: other}) || !f.s.wantsPush(f.ctx, alice, invite) {
		t.Fatal("muting a room silenced something else")
	}
	// A muted chat is quiet for its messages, but a call from that person still rings.
	f.must("notify_mute", f.alice, map[string]any{"kind": "peer", "id": chat, "muted": true})
	if f.s.wantsPush(f.ctx, alice, dm) || !f.s.wantsPush(f.ctx, alice, call) {
		t.Fatal("a muted chat must stop its messages but not its calls")
	}
	// Muting twice keeps one entry; unmuting lets it through again.
	f.must("notify_mute", f.alice, map[string]any{"kind": "space", "id": room, "muted": true})
	view := f.must("notify_prefs", f.alice, nil)
	if n := len(view["muted_spaces"].([]any)); n != 1 {
		t.Fatalf("muted rooms = %v", view["muted_spaces"])
	}
	f.must("notify_mute", f.alice, map[string]any{"kind": "space", "id": room, "muted": false})
	f.must("notify_mute", f.alice, map[string]any{"kind": "peer", "id": chat, "muted": false})
	if !f.s.wantsPush(f.ctx, alice, rooms) || !f.s.wantsPush(f.ctx, alice, dm) {
		t.Fatal("unmuting did not let notifications through")
	}
	if _, err := f.call("notify_mute", f.alice, map[string]any{"kind": "thing", "id": room, "muted": true}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("unknown kind: %v", err)
	}
	if _, err := f.call("notify_mute", f.alice, map[string]any{"kind": "space", "id": "nope", "muted": true}); err == nil {
		t.Fatal("a bad id was accepted")
	}
}
