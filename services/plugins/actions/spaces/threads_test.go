package spaces

import (
	"context"
	"encoding/json"
	"sync"
	"testing"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// forgotten records the rooms the fake agent runtime was told to forget.
var forgotten = struct {
	sync.Mutex
	rooms []string
}{}

func (f *fakeAgentRuntime) ForgetRoom(_ context.Context, _, roomID string) error {
	forgotten.Lock()
	defer forgotten.Unlock()
	forgotten.rooms = append(forgotten.rooms, roomID)
	return nil
}

type threadOut struct {
	ID     string `json:"id"`
	RoomID string `json:"room_id"`
	Title  string `json:"title"`
}

func threadsOf(t *testing.T, s *Service, ctx context.Context, caller, sp, room identity.ID) (main map[string]any, threads []threadOut) {
	t.Helper()
	var out struct {
		Main    map[string]any `json:"main"`
		Threads []threadOut    `json:"threads"`
	}
	callAs(t, ctx, caller, s.threadList, map[string]any{"space": sp.String(), "room": room.String()}, &out)
	return out.Main, out.Threads
}

// A room's threads each keep their own conversation; the room is the main
// thread, and listings, grants and the desk stay the room's.
func TestRoomThreadsKeepTheirOwnConversation(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	stranger := directPerson(t, s, ctx, "00000000000000010000000000000009", "stranger")
	sp, err := s.CreateSpace(ctx, owner, "launch", "")
	if err != nil {
		t.Fatal(err)
	}
	room, err := s.generalRoom(ctx, sp.ID)
	if err != nil {
		t.Fatal(err)
	}
	var created struct {
		Thread threadOut `json:"thread"`
	}
	callAs(t, ctx, owner, s.threadCreate, map[string]any{"space": sp.ID.String(), "room": room.ID.String()}, &created)
	if created.Thread.RoomID != room.ID.String() || created.Thread.Title != newThreadTitle {
		t.Fatalf("created: %+v", created.Thread)
	}
	if err := callErr(ctx, stranger, s.threadCreate, map[string]any{"space": sp.ID.String(), "room": room.ID.String()}); err == nil {
		t.Fatal("a stranger opened a thread")
	}
	thread := idFromHex(t, created.Thread.ID)

	sendIn(t, s, ctx, owner, sp.ID, room.ID, "in the main thread")
	sendIn(t, s, ctx, owner, sp.ID, thread, "Plan the pricing page")
	sendIn(t, s, ctx, owner, sp.ID, thread, "and the FAQ")

	if got := listIn(t, s, ctx, owner, sp.ID, room.ID).Messages; len(got) != 1 || got[0]["body"] != "in the main thread" {
		t.Fatalf("main thread: %v", got)
	}
	if got := listIn(t, s, ctx, owner, sp.ID, thread).Messages; len(got) != 2 {
		t.Fatalf("thread: %v", got)
	}
	main, threads := threadsOf(t, s, ctx, owner, sp.ID, room.ID)
	if main["id"] != room.ID.String() || len(threads) != 1 || threads[0].Title != "Plan the pricing page" {
		t.Fatalf("threads: %v %+v", main, threads)
	}
	// Listing from the thread lists the same room's threads.
	if _, again := threadsOf(t, s, ctx, owner, sp.ID, thread); len(again) != 1 {
		t.Fatalf("listed from the thread: %+v", again)
	}

	var rooms struct {
		Rooms []space.Room `json:"rooms"`
	}
	callAs(t, ctx, owner, (&roomListAction{s: s}).Handle, map[string]any{"space": sp.ID.String()}, &rooms)
	if len(rooms.Rooms) != 1 || rooms.Rooms[0].ID != room.ID {
		t.Fatalf("room list shows threads: %+v", rooms.Rooms)
	}
	if s.mainRoom(ctx, thread) != room.ID || s.mainRoom(ctx, room.ID) != room.ID {
		t.Fatal("a thread does not resolve to its room")
	}
	if _, _, err := s.UpdateDesk(ctx, sp.ID, thread, "owner", []DeskOp{{Op: "open", Tool: "notes", Title: "Notes"}}); err != nil {
		t.Fatal(err)
	}
	if d, _ := s.Desk(ctx, sp.ID, room.ID); len(d.Windows) != 1 {
		t.Fatalf("a thread has a desk of its own: %+v", d.Windows)
	}

	var ok map[string]any
	callAs(t, ctx, owner, s.threadRename, map[string]any{"thread": thread.String(), "title": "Pricing"}, &ok)
	if _, threads := threadsOf(t, s, ctx, owner, sp.ID, room.ID); threads[0].Title != "Pricing" {
		t.Fatalf("rename: %+v", threads)
	}
	if err := callErr(ctx, owner, s.threadDelete, map[string]any{"thread": room.ID.String()}); err == nil {
		t.Fatal("the main thread was deleted as a thread")
	}
	callAs(t, ctx, owner, s.threadDelete, map[string]any{"thread": thread.String()}, &ok)
	if _, threads := threadsOf(t, s, ctx, owner, sp.ID, room.ID); len(threads) != 0 {
		t.Fatalf("deleted thread listed: %+v", threads)
	}
	if n, _ := s.R.Count(ctx, "messages", database.Filter{Equal: map[string]any{"room_id": thread.String()}}); n != 0 {
		t.Fatalf("%d messages of a deleted thread remain", n)
	}
	if got := listIn(t, s, ctx, owner, sp.ID, room.ID).Messages; len(got) != 1 {
		t.Fatalf("the main thread lost messages: %v", got)
	}
}

// An app's ask runs in a temporary thread of its own, which is deleted (its
// messages, and the agent's conversation in the runtime) once the agent answers.
func TestAnAppsAskRunsInATemporaryThreadDeletedAfter(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "launch", "")
	if err != nil {
		t.Fatal(err)
	}
	room, err := s.generalRoom(ctx, sp.ID)
	if err != nil {
		t.Fatal(err)
	}
	billed := &billLog{}
	s.Bots = sandboxBots{mentionBots{BotPort: s.Bots, billed: billed}}
	rt := bootRuntime(t, s, ctx)
	helper := addAgent(t, s, ctx, sp.ID, "helper", "g-helper")
	addSandbox(t, s, ctx, sp.ID)

	ask := func(body map[string]any) string {
		raw, _ := json.Marshal(body)
		resp, err := (&spaceAskAction{s: s}).Handle(ctx, &api.ActionRequest{Caller: api.Caller{ID: owner, Kind: "user"}, Body: raw})
		if err != nil {
			t.Fatal(err)
		}
		var out struct {
			Reply string `json:"reply"`
		}
		_ = json.Unmarshal(resp.Body, &out)
		return out.Reply
	}
	body := map[string]any{"space": sp.ID.String(), "room": room.ID.String(), "bot": helper.ID.String(),
		"body": "summarise the notes", "temp_thread": true,
		"history": []map[string]any{{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}}}
	if reply := ask(body); reply != "done by helper" {
		t.Fatalf("reply: %q", reply)
	}
	if reply := ask(body); reply != "done by helper" {
		t.Fatalf("second reply: %q", reply)
	}

	rt.mu.Lock()
	first, second := rt.prompts[0], rt.prompts[1]
	rt.mu.Unlock()
	if first.RoomID == room.ID.String() || first.RoomID == second.RoomID {
		t.Fatalf("asks did not get threads of their own: %s %s (room %s)", first.RoomID, second.RoomID, room.ID)
	}
	if want := "Our conversation so far:\nMe: hi\nYou: hello\n\nNow: summarise the notes"; first.Message != want {
		t.Fatalf("the history did not travel with the ask: %q", first.Message)
	}
	var left []space.Room
	if err := s.R.List(ctx, "rooms", database.Filter{Equal: map[string]any{"parent_id": room.ID.String()}}, &left); err != nil || len(left) != 0 {
		t.Fatalf("temporary threads left behind: %+v %v", left, err)
	}
	for _, id := range []string{first.RoomID, second.RoomID} {
		if n, _ := s.R.Count(ctx, "messages", database.Filter{Equal: map[string]any{"room_id": id}}); n != 0 {
			t.Fatalf("%d messages of a temporary thread remain", n)
		}
	}
	forgotten.Lock()
	gone := append([]string(nil), forgotten.rooms...)
	forgotten.Unlock()
	if !contains(gone, first.RoomID) || !contains(gone, second.RoomID) {
		t.Fatalf("the runtime did not forget the threads: %v", gone)
	}
	if got := listIn(t, s, ctx, owner, sp.ID, room.ID).Messages; len(got) != 0 {
		t.Fatalf("an app's ask leaked into the room: %v", got)
	}
	// Each ask is charged once, to the person who asked, for the agent.
	charges := billed.all()
	if len(charges) != 2 {
		t.Fatalf("two asks were charged %d times: %+v", len(charges), charges)
	}
	for _, c := range charges {
		if c.payer != owner || c.bot != helper.ID {
			t.Fatalf("charged %+v, want the asker for the agent", c)
		}
	}
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}
