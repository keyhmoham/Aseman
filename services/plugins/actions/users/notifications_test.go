package users

import (
	"testing"

	"github.com/tradera/tradera/internal/plugins/identity"
)

// Every pushed notification lands in the person's inbox, newest first, even
// with no phone to send it to; a collapsing one replaces its predecessor.
func TestPushKeepsNotificationsInTheInbox(t *testing.T) {
	s, ctx := followHarness(t)
	alice := mustID(t, "00000000000000010000000000000001")
	bob := mustID(t, "00000000000000010000000000000002")

	s.Push(ctx, []identity.ID{alice}, PushNote{Title: "Room invitation", Body: "bob invited you", Kind: "invite"})
	s.Push(ctx, []identity.ID{alice, bob}, PushNote{Title: "Desk", Body: "first", Kind: "message", Collapse: "m1"})
	s.Push(ctx, []identity.ID{alice}, PushNote{Title: "Desk", Body: "second", Kind: "message", Collapse: "m1"})

	list, unread, err := s.Notifications(ctx, alice, 30, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 2 || unread != 2 {
		t.Fatalf("alice has %d notifications, %d unread; want 2, 2: %+v", len(list), unread, list)
	}
	if list[0].Body != "second" || list[1].Kind != "invite" {
		t.Fatalf("not newest first, or not collapsed: %+v", list)
	}
	if err := s.MarkNotificationsRead(ctx, alice); err != nil {
		t.Fatal(err)
	}
	if _, unread, _ := s.Notifications(ctx, alice, 30, 0); unread != 0 {
		t.Fatalf("%d unread after marking read", unread)
	}
	// Bob's inbox is his own and untouched by alice reading hers.
	if list, unread, _ := s.Notifications(ctx, bob, 30, 0); len(list) != 1 || unread != 1 {
		t.Fatalf("bob has %d notifications, %d unread; want 1, 1", len(list), unread)
	}
}
