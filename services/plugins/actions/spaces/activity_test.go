package spaces

import (
	"context"
	"testing"
	"time"

	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func TestRoomActivityRegistry(t *testing.T) {
	s := &Service{activity: map[string]map[string]roomActivity{}}
	room := idFromHex(t, "00000000000000020000000000000001")
	if _, _, ok := s.RoomActivity(room); ok {
		t.Fatal("expected no activity initially")
	}
	s.SetRoomActivity(context.Background(), room, "helper", "running in the sandbox…")
	agent, detail, ok := s.RoomActivity(room)
	if !ok || agent != "helper" || detail != "running in the sandbox…" {
		t.Fatalf("activity = %q %q %v", agent, detail, ok)
	}
	s.SetRoomActivity(context.Background(), room, "helper", "")
	if _, _, ok := s.RoomActivity(room); ok {
		t.Fatal("expected cleared activity")
	}
}

func TestRoomActivityTTLDropsStale(t *testing.T) {
	s := &Service{activity: map[string]map[string]roomActivity{}}
	room := idFromHex(t, "00000000000000020000000000000001")
	s.activity[room.String()] = map[string]roomActivity{"aseman": {Agent: "aseman", Detail: "planning", At: time.Now().Add(-4 * time.Minute)}}
	if _, _, ok := s.RoomActivity(room); ok {
		t.Fatal("expected stale activity to be dropped")
	}
}

func TestSeveralAgentsWorkInOneRoom(t *testing.T) {
	s := &Service{activity: map[string]map[string]roomActivity{}}
	room := idFromHex(t, "00000000000000020000000000000001")
	ctx, done := s.activityWriter(context.Background(), room)
	hook := vmm.StatusFrom(ctx)
	hook("lead", "delegating…")
	hook("researcher", "searching…")
	if all := s.RoomActivities(room); len(all) != 2 {
		t.Fatalf("activities = %+v", all)
	}
	// Another delivery in the same room keeps its own agent's status.
	other, otherDone := s.activityWriter(context.Background(), room)
	vmm.StatusFrom(other)("writer", "drafting…")
	done()
	if all := s.RoomActivities(room); len(all) != 1 || all[0].Agent != "writer" {
		t.Fatalf("done cleared another delivery's status: %+v", all)
	}
	otherDone()
	if len(s.RoomActivities(room)) != 0 {
		t.Fatal("expected no activity")
	}
}

func TestActivityWriterClears(t *testing.T) {
	s := &Service{activity: map[string]map[string]roomActivity{}}
	room := idFromHex(t, "00000000000000020000000000000001")
	ctx, done := s.activityWriter(context.Background(), room)
	if hook := vmm.StatusFrom(ctx); hook == nil {
		t.Fatal("expected status hook on ctx")
	} else {
		hook("helper", "thinking…")
	}
	if _, detail, ok := s.RoomActivity(room); !ok || detail != "thinking…" {
		t.Fatalf("activity after hook = %q %v", detail, ok)
	}
	done()
	if _, _, ok := s.RoomActivity(room); ok {
		t.Fatal("expected activity cleared by done")
	}
}

func TestToolDetailSentences(t *testing.T) {
	for tool, want := range map[string]string{
		"sandbox_exec":   "running in the sandbox…",
		"image_generate": "generating an image…",
		"file_send":      "sending a file…",
		"file_read":      "reading a file…",
		"unknown_tool":   "using tool unknown_tool…",
	} {
		if got := toolDetail(tool); got != want {
			t.Fatalf("toolDetail(%q) = %q, want %q", tool, got, want)
		}
	}
}

// A room's answer in progress is published as a draft, wakes whoever follows
// the room, survives status updates and goes away with the agent's activity.
func TestRoomDraftIsFollowedLive(t *testing.T) {
	s := &Service{activity: map[string]map[string]roomActivity{}}
	room := idFromHex(t, "00000000000000010000000000000009")
	seq, changed := s.liveWait()
	s.SetRoomActivity(context.Background(), room, "aseman", "thinking…")
	select {
	case <-changed:
	default:
		t.Fatal("a status change did not wake the room's followers")
	}
	s.SetRoomDraft(context.Background(), room, "aseman", "Light attracts")
	s.SetRoomActivity(context.Background(), room, "aseman", "thinking…")
	if all := s.RoomActivities(room); len(all) != 1 || all[0].Draft != "Light attracts" {
		t.Fatalf("draft lost: %+v", all)
	}
	if next, _ := s.liveWait(); next <= seq {
		t.Fatalf("seq did not advance: %d -> %d", seq, next)
	}
	s.SetRoomActivity(context.Background(), room, "aseman", "")
	if all := s.RoomActivities(room); len(all) != 0 {
		t.Fatalf("draft outlived the turn: %+v", all)
	}
}
