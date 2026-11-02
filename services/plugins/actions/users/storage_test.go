package users

import (
	"context"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
)

// addRoomFile puts a file of `size` bytes uploaded by `uploader` into room `sp`.
func (f *dmFixture) addRoomFile(sp, uploader identity.ID, name string, size int64) string {
	f.t.Helper()
	id, err := identity.New(f.s.K.NodeID())
	if err != nil {
		f.t.Fatal(err)
	}
	now := time.Now().UTC()
	file := &filedata.File{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, OwnerID: uploader, SpaceID: sp, Name: name, Mime: "image/png", Size: size, StorageKey: "rooms/" + id.String()}
	if err := f.s.R.CreateID(f.ctx, "files", id, file); err != nil {
		f.t.Fatal(err)
	}
	time.Sleep(2 * time.Millisecond)
	return id.String()
}

func (f *dmFixture) addRoom(owner identity.ID, name string) identity.ID {
	f.t.Helper()
	id, err := identity.New(f.s.K.NodeID())
	if err != nil {
		f.t.Fatal(err)
	}
	now := time.Now().UTC()
	if err := f.s.R.CreateID(f.ctx, "spaces", id, &space.Space{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, OwnerID: owner, Name: name}); err != nil {
		f.t.Fatal(err)
	}
	return id
}

func TestStorageOverviewAddsUpWhatAPersonIsResponsibleFor(t *testing.T) {
	f := dmHarness(t)
	alice, bob := f.alice.ID, f.bob.ID

	// Alice sends bob 1000 bytes and keeps 300 in her notes; bob sends her 50.
	a := f.upload("alice", bob.String(), "a.bin", "", 1000)["file_id"].(string)
	f.must("dm_send", f.alice, map[string]any{"to": bob.String(), "attachments": []string{a}})
	n := f.upload("alice", alice.String(), "note.bin", "", 300)["file_id"].(string)
	f.must("dm_send", f.alice, map[string]any{"to": alice.String(), "attachments": []string{n}})
	b := f.upload("bob", alice.String(), "b.bin", "", 50)["file_id"].(string)
	f.must("dm_send", f.bob, map[string]any{"to": alice.String(), "attachments": []string{b}})

	// Alice owns a room where bob also uploaded; bob owns one alice uploaded to.
	aliceRoom := f.addRoom(alice, "Launch")
	bobRoom := f.addRoom(bob, "Bob's")
	f.addRoomFile(aliceRoom, alice, "plan.png", 4000)
	f.addRoomFile(aliceRoom, bob, "bobs.png", 2000)
	f.addRoomFile(bobRoom, alice, "hers.png", 9000)

	use := f.must("storage_usage", f.alice, nil)
	// Chats 1300 (not the 50 bob sent), rooms 6000 (her room, from both; not the file she put in bob's room).
	if use["chats_bytes"] != float64(1300) || use["rooms_bytes"] != float64(6000) || use["other_bytes"] != float64(0) || use["used_bytes"] != float64(7300) {
		t.Fatalf("alice uses %v", use)
	}
	chats := use["chats"].([]any)
	if len(chats) != 2 || chats[0].(map[string]any)["bytes"] != float64(1000) || chats[1].(map[string]any)["saved"] != true {
		t.Fatalf("chats = %v", chats)
	}
	rooms := use["rooms"].([]any)
	if len(rooms) != 1 || rooms[0].(map[string]any)["name"] != "Launch" || rooms[0].(map[string]any)["files"] != float64(2) {
		t.Fatalf("rooms = %v", rooms)
	}
	// The upload limit counts the same total the screen shows.
	f.s.StorageLimit = func(context.Context) int64 { return 7300 }
	if _, err := f.call("dm_file_upload", f.alice, map[string]any{"to": bob.String(), "name": "x.bin", "data": "eA=="}); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("one byte over the same total: %v", err)
	}
}

func TestStorageFilesPageAndDelete(t *testing.T) {
	f := dmHarness(t)
	bob := f.bob.ID.String()
	var ids []string
	for i := 0; i < 3; i++ {
		id := f.upload("alice", bob, "f"+string(rune('a'+i))+".bin", "", 100)["file_id"].(string)
		ids = append(ids, id)
	}
	// One message with two files, one with a file and text, so deleting shows both outcomes.
	f.must("dm_send", f.alice, map[string]any{"to": bob, "attachments": []string{ids[0], ids[1]}})
	f.must("dm_send", f.alice, map[string]any{"to": bob, "body": "look", "attachments": []string{ids[2]}})

	page := f.must("storage_files", f.alice, map[string]any{"kind": "chat", "id": bob})
	files := page["files"].([]any)
	if len(files) != 3 || page["next"] != nil {
		t.Fatalf("page = %v", page)
	}
	// Bob can't list or delete alice's files.
	if got := f.must("storage_files", f.bob, map[string]any{"kind": "chat", "id": f.alice.ID.String()})["files"].([]any); len(got) != 0 {
		t.Fatalf("bob lists %v", got)
	}
	del := f.must("storage_delete", f.bob, map[string]any{"kind": "chat", "files": []string{ids[0]}})
	if del["deleted"] != float64(0) {
		t.Fatalf("bob deleted alice's file: %v", del)
	}

	// Deleting the only file of the text-only message keeps the text; of the two-file
	// message, one at a time: first leaves the other, second takes the message back.
	f.must("storage_delete", f.alice, map[string]any{"kind": "chat", "files": []string{ids[2]}})
	f.must("storage_delete", f.alice, map[string]any{"kind": "chat", "files": []string{ids[0]}})
	msgs := f.must("dm_list", f.bob, map[string]any{"peer": f.alice.ID.String()})["messages"].([]any)
	if len(msgs) != 2 {
		t.Fatalf("messages = %v", msgs)
	}
	f.must("storage_delete", f.alice, map[string]any{"kind": "chat", "files": []string{ids[1]}})
	msgs = f.must("dm_list", f.bob, map[string]any{"peer": f.alice.ID.String()})["messages"].([]any)
	if len(msgs) != 1 || msgs[0].(map[string]any)["body"] != "look" {
		t.Fatalf("after all deleted: %v", msgs)
	}
	if got := f.must("storage_usage", f.alice, nil)["used_bytes"]; got != float64(0) {
		t.Fatalf("alice still uses %v", got)
	}
}

func TestOnlyTheRoomOwnerSeesAndDeletesRoomFiles(t *testing.T) {
	f := dmHarness(t)
	room := f.addRoom(f.alice.ID, "Launch")
	theirs := f.addRoomFile(room, f.bob.ID, "bobs.png", 700)

	got := f.must("storage_files", f.alice, map[string]any{"kind": "room", "id": room.String()})["files"].([]any)
	if len(got) != 1 || got[0].(map[string]any)["uploader"] == nil {
		t.Fatalf("owner lists %v", got)
	}
	if _, err := f.call("storage_files", f.bob, map[string]any{"kind": "room", "id": room.String()}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a member listed the room's storage: %v", err)
	}
	if del := f.must("storage_delete", f.bob, map[string]any{"kind": "room", "files": []string{theirs}}); del["deleted"] != float64(0) {
		t.Fatalf("a member deleted a room file: %v", del)
	}
	del := f.must("storage_delete", f.alice, map[string]any{"kind": "room", "files": []string{theirs}})
	if del["deleted"] != float64(1) || del["freed_bytes"] != float64(700) {
		t.Fatalf("owner delete = %v", del)
	}
	if got := f.must("storage_usage", f.alice, nil)["rooms_bytes"]; got != float64(0) {
		t.Fatalf("room still uses %v", got)
	}
}
