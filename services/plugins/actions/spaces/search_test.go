package spaces

import (
	"testing"
)

// The space search finds the caller's projects and public ones by name, never
// a direct chat or someone else's private project.
func TestSpaceSearchCoversMyAndPublicSpaces(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
	bob := directPerson(t, s, ctx, "00000000000000010000000000000002", "bob")
	mine, err := s.CreateSpace(ctx, alice, "Macro desk", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateSpace(ctx, bob, "Private macro", ""); err != nil {
		t.Fatal(err)
	}
	open, err := s.CreateSpace(ctx, bob, "Open macro club", "")
	if err != nil {
		t.Fatal(err)
	}
	open.Public = true
	if err := s.R.Update(ctx, "spaces", open.ID, open); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.OpenDirect(ctx, alice, bob); err != nil {
		t.Fatal(err)
	}

	var out struct {
		Spaces []map[string]any `json:"spaces"`
	}
	callAs(t, ctx, alice, (&spaceSearchAction{s: s}).Handle, map[string]any{"query": "MACRO"}, &out)
	if len(out.Spaces) != 2 || out.Spaces[0]["id"] != mine.ID.String() || out.Spaces[1]["id"] != open.ID.String() {
		t.Fatalf("spaces: %v", out.Spaces)
	}
	if out.Spaces[0]["member"] != true || out.Spaces[1]["member"] != false {
		t.Fatalf("membership flags: %v", out.Spaces)
	}
}

// A chat search keeps the direct chats whose other side's name holds it.
func TestChatListFiltersDirectChatsByPeer(t *testing.T) {
	s, ctx := fileToolHarness(t)
	alice := directPerson(t, s, ctx, "00000000000000010000000000000001", "alice")
	bob := directPerson(t, s, ctx, "00000000000000010000000000000002", "bob")
	carol := directPerson(t, s, ctx, "00000000000000010000000000000003", "carol")
	if _, _, err := s.OpenDirect(ctx, alice, bob); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.OpenDirect(ctx, alice, carol); err != nil {
		t.Fatal(err)
	}
	var out struct {
		Chats []map[string]any `json:"chats"`
	}
	callAs(t, ctx, alice, s.chatList, map[string]any{"kind": "direct", "query": "CAR"}, &out)
	if len(out.Chats) != 1 {
		t.Fatalf("chats: %v", out.Chats)
	}
	if peer, _ := out.Chats[0]["peer"].(map[string]any); peer["handle"] != "carol" {
		t.Fatalf("peer: %v", out.Chats[0]["peer"])
	}
}
