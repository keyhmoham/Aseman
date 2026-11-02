package users

import (
	"context"
	"reflect"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
)

func TestPrivacyDefaultsAndChanges(t *testing.T) {
	f := dmHarness(t)
	got := f.must("privacy_get", f.alice, nil)
	if got["messages"] != "everyone" || got["calls_voice"] != "everyone" || got["calls_video"] != "everyone" || got["invites"] != "everyone" {
		t.Fatalf("defaults = %v (everything starts open to everyone)", got)
	}
	// Naming one choice leaves the others.
	got = f.must("privacy_set", f.alice, map[string]any{"calls_video": "nobody"})
	if got["calls_video"] != "nobody" || got["calls_voice"] != "everyone" || got["invites"] != "everyone" || got["messages"] != "everyone" {
		t.Fatalf("after set = %v", got)
	}
	// It is the caller's own, and a made-up value is refused.
	if f.must("privacy_get", f.bob, nil)["calls_video"] != "everyone" {
		t.Fatal("alice's choice reached bob")
	}
	if _, err := f.call("privacy_set", f.alice, map[string]any{"invites": "friends"}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("made-up audience: %v", err)
	}
	if f.must("privacy_get", f.alice, nil)["invites"] != "everyone" {
		t.Fatal("a refused change was saved")
	}
}

func TestCallsFollowWhoMayCallMe(t *testing.T) {
	f := dmHarness(t)
	alice, bob := f.alice.ID.String(), f.bob.ID.String()

	// Bob takes calls from people he has messaged: alice, a stranger, may not call.
	f.must("privacy_set", f.bob, map[string]any{"calls_voice": "contacts", "calls_video": "contacts"})
	if _, err := f.call("call_start", f.alice, map[string]any{"to": bob}); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("a stranger rang bob: %v", err)
	}
	// Alice messaging bob does not make her his contact (or one message would be enough to be called)...
	f.send(f.alice, f.bob, "hi bob")
	if _, err := f.call("call_start", f.alice, map[string]any{"to": bob}); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("someone who only messaged bob rang him: %v", err)
	}
	// ...bob messaging alice does.
	f.send(f.bob, f.alice, "hi alice")
	id := f.must("call_start", f.alice, map[string]any{"to": bob})["call"].(map[string]any)["id"].(string)
	f.must("call_end", f.alice, map[string]any{"id": id})

	// Voice and video are separate choices.
	f.must("privacy_set", f.bob, map[string]any{"calls_video": "nobody"})
	if _, err := f.call("call_start", f.alice, map[string]any{"to": bob, "video": true}); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("a video call to someone taking none: %v", err)
	}
	id = f.must("call_start", f.alice, map[string]any{"to": bob, "video": false})["call"].(map[string]any)["id"].(string)
	f.must("call_end", f.alice, map[string]any{"id": id})

	// Nobody means nobody, contacts included; everyone means anyone.
	f.must("privacy_set", f.bob, map[string]any{"calls_voice": "nobody"})
	if _, err := f.call("call_start", f.alice, map[string]any{"to": bob}); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("a voice call to someone taking none: %v", err)
	}
	f.must("privacy_set", f.bob, map[string]any{"calls_voice": "everyone"})
	f.must("call_end", f.alice, map[string]any{"id": f.must("call_start", f.alice, map[string]any{"to": bob})["call"].(map[string]any)["id"].(string)})

	// A block wins over everyone, and the refusal is the same whatever caused it.
	f.must("dm_block", f.bob, map[string]any{"peer": alice})
	if _, err := f.call("call_start", f.alice, map[string]any{"to": bob}); err == nil {
		t.Fatal("a blocked caller got through")
	}
}

func TestInvitesFollowWhoMayInviteMe(t *testing.T) {
	f := dmHarness(t)
	alice, bob := f.alice.ID, f.bob.ID

	// Everyone, by default.
	if err := f.s.AllowsInvite(f.ctx, alice, bob); err != nil {
		t.Fatalf("default: %v", err)
	}
	// Contacts: someone bob has messaged.
	f.must("privacy_set", f.bob, map[string]any{"invites": "contacts"})
	if err := f.s.AllowsInvite(f.ctx, alice, bob); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a stranger invited bob: %v", err)
	}
	f.send(f.bob, f.alice, "hello")
	if err := f.s.AllowsInvite(f.ctx, alice, bob); err != nil {
		t.Fatalf("a contact was refused: %v", err)
	}
	// Nobody.
	f.must("privacy_set", f.bob, map[string]any{"invites": "nobody"})
	if err := f.s.AllowsInvite(f.ctx, alice, bob); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("an invitation to someone taking none: %v", err)
	}
	// A block wins over everyone.
	f.must("privacy_set", f.bob, map[string]any{"invites": "everyone"})
	f.must("dm_block", f.bob, map[string]any{"peer": alice.String()})
	if err := f.s.AllowsInvite(f.ctx, alice, bob); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a blocked person invited bob: %v", err)
	}
	// Inviting yourself is yours to do.
	if err := f.s.AllowsInvite(f.ctx, alice, alice); err != nil {
		t.Fatalf("self: %v", err)
	}
}

// The rooms service reaches AllowsInvite through the service bridge, which finds the
// method by name and passes (ctx, inviter, invitee); a change of shape would make that
// call fail in a way the rooms service treats as "no choices to honour". This pins it.
func TestAllowsInviteKeepsTheShapeTheBridgeCalls(t *testing.T) {
	m, ok := reflect.TypeOf(&Service{}).MethodByName("AllowsInvite")
	if !ok {
		t.Fatal("AllowsInvite is gone")
	}
	typ := m.Type // the receiver is its first argument
	ctxType := reflect.TypeOf((*context.Context)(nil)).Elem()
	idType := reflect.TypeOf(identity.ID{})
	errType := reflect.TypeOf((*error)(nil)).Elem()
	if typ.NumIn() != 4 || typ.In(1) != ctxType || typ.In(2) != idType || typ.In(3) != idType || typ.NumOut() != 1 || typ.Out(0) != errType {
		t.Fatalf("AllowsInvite is %v; the bridge calls it with (ctx, inviter, invitee) and reads one error", typ)
	}
}

func TestMessagesFollowWhoMayMessageMe(t *testing.T) {
	f := dmHarness(t)
	alice, bob := f.alice.ID, f.bob.ID

	// Open to everyone, by default.
	f.send(f.alice, f.bob, "hello")

	// People bob has messaged: alice, who has only written to him, is not one.
	f.must("privacy_set", f.bob, map[string]any{"messages": "contacts"})
	if _, err := f.call("dm_send", f.alice, map[string]any{"to": bob.String(), "body": "again"}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a stranger messaged bob: %v", err)
	}
	// The refusal is the words of a block, so it does not say which it was (compared below).
	_, refused := f.call("dm_send", f.alice, map[string]any{"to": bob.String(), "body": "again"})
	// Once bob has written to alice she is his contact, and may answer.
	f.send(f.bob, f.alice, "hi alice")
	f.send(f.alice, f.bob, "hi bob, answering")

	// Nobody: not even a contact; his own notes stay his.
	f.must("privacy_set", f.bob, map[string]any{"messages": "nobody"})
	if _, err := f.call("dm_send", f.alice, map[string]any{"to": bob.String(), "body": "still?"}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a contact messaged someone taking none: %v", err)
	}
	f.must("dm_send", f.bob, map[string]any{"to": bob.String(), "body": "a note to myself"})
	// Choosing does not stop bob writing to others, nor alice's own choice from applying to him.
	f.must("dm_send", f.bob, map[string]any{"to": alice.String(), "body": "I can still write"})

	// Files are messages: they follow the same choice.
	if _, err := f.call("dm_file_upload", f.alice, map[string]any{"to": bob.String(), "name": "x.bin", "data": "eA=="}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a file to someone taking no messages: %v", err)
	}

	// The conversation says so (and a block is told apart, for calls).
	view := f.must("dm_list", f.alice, map[string]any{"peer": bob.String()})
	if view["can_send"] != false || view["blocked_either"] != false {
		t.Fatalf("view = %v", view)
	}
	f.must("privacy_set", f.bob, map[string]any{"messages": "everyone"})
	if f.must("dm_list", f.alice, map[string]any{"peer": bob.String()})["can_send"] != true {
		t.Fatal("opening messages to everyone did not let alice write")
	}
	f.must("dm_block", f.bob, map[string]any{"peer": alice.String()})
	view = f.must("dm_list", f.alice, map[string]any{"peer": bob.String()})
	if view["can_send"] != false || view["blocked_either"] != true {
		t.Fatalf("after a block = %v", view)
	}
	// The refusal a block gives reads exactly as the choice's did.
	if _, blocked := f.call("dm_send", f.alice, map[string]any{"to": bob.String(), "body": "x"}); blocked == nil || refused == nil || blocked.Error() != refused.Error() {
		t.Fatalf("a block says %v, the choice said %v: a sender could tell them apart", blocked, refused)
	}
}
