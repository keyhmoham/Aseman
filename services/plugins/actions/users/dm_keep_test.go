package users

import (
	"context"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
)

func (f *dmFixture) sendFile(from string, to string, size int) (messageID, fileID string) {
	f.t.Helper()
	fileID = f.upload(from, to, "photo.png", "image/png", size)["file_id"].(string)
	caller := f.alice
	if from == "bob" {
		caller = f.bob
	}
	return f.must("dm_send", caller, map[string]any{"to": to, "attachments": []string{fileID}})["id"].(string), fileID
}

func TestKeepingAFileSurvivesTheSenderDeletingIt(t *testing.T) {
	f := dmHarness(t)
	alice, bob := f.alice.ID.String(), f.bob.ID.String()
	msg, file := f.sendFile("alice", bob, 1000)

	// Only the person it was sent to can keep it: not the sender, not a stranger's request.
	if _, err := f.call("dm_keep", f.alice, map[string]any{"message": msg}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("sender kept their own file: %v", err)
	}

	kept := f.must("dm_keep", f.bob, map[string]any{"message": msg})["kept"].(map[string]any)
	keptID := kept[file].(string)
	if keptID == "" || keptID == file {
		t.Fatalf("kept = %v", kept)
	}
	// Keeping again changes nothing.
	again := f.must("dm_keep", f.bob, map[string]any{"message": msg})["kept"].(map[string]any)
	if again[file] != keptID {
		t.Fatalf("second keep made %v", again)
	}

	// Bob sees it marked; Alice doesn't. Both are charged the whole size.
	att := firstMessage(f.must("dm_list", f.bob, map[string]any{"peer": alice}))["attachments"].([]any)[0].(map[string]any)
	if att["kept"] != true {
		t.Fatalf("bob's view %v", att)
	}
	att = firstMessage(f.must("dm_list", f.alice, map[string]any{"peer": bob}))["attachments"].([]any)[0].(map[string]any)
	if att["kept"] != nil {
		t.Fatalf("alice sees it as kept: %v", att)
	}
	use := f.must("storage_usage", f.bob, nil)
	if use["kept_bytes"] != float64(1000) || use["used_bytes"] != float64(1000) || use["chats_bytes"] != float64(0) {
		t.Fatalf("bob uses %v", use)
	}
	keptGroups := use["kept"].([]any)
	if len(keptGroups) != 1 || keptGroups[0].(map[string]any)["files"] != float64(1) {
		t.Fatalf("kept groups = %v", keptGroups)
	}

	// One set of bytes under both records: no second copy.
	key := f.storageKey(file)
	if key == "" || f.storageKey(keptID) != key {
		t.Fatalf("kept file does not share the bytes: %q vs %q", key, f.storageKey(keptID))
	}
	if !f.bytesExist(key) {
		t.Fatal("no bytes stored")
	}

	// Alice takes the message back: her storage is freed, Bob still has the file.
	f.must("dm_unsend", f.alice, map[string]any{"id": msg})
	if !f.bytesExist(key) {
		t.Fatal("the bytes went with the sender's file although Bob kept it")
	}
	if got := f.must("storage_usage", f.alice, nil)["used_bytes"]; got != float64(0) {
		t.Fatalf("alice still uses %v", got)
	}
	if _, err := f.call("file_download", f.bob, map[string]any{"file": keptID}); err != nil {
		t.Fatalf("bob lost the file he kept: %v", err)
	}
	if got := f.must("storage_usage", f.bob, nil)["used_bytes"]; got != float64(1000) {
		t.Fatalf("bob uses %v", got)
	}

	// Bob lists and deletes it; now the bytes go.
	page := f.must("storage_files", f.bob, map[string]any{"kind": "kept", "id": alice})["files"].([]any)
	if len(page) != 1 || page[0].(map[string]any)["id"] != keptID {
		t.Fatalf("kept page = %v", page)
	}
	if del := f.must("storage_delete", f.alice, map[string]any{"kind": "kept", "files": []string{keptID}}); del["deleted"] != float64(0) {
		t.Fatalf("alice deleted bob's kept file: %v", del)
	}
	del := f.must("storage_delete", f.bob, map[string]any{"kind": "kept", "files": []string{keptID}})
	if del["deleted"] != float64(1) || del["freed_bytes"] != float64(1000) {
		t.Fatalf("delete = %v", del)
	}
	if _, err := f.call("file_download", f.bob, map[string]any{"file": keptID}); err == nil {
		t.Fatal("the file is still there after the last record went")
	}
	if f.bytesExist(key) {
		t.Fatal("the bytes outlived the last record")
	}
}

func TestBytesStayWhileAnyoneStillHasTheFile(t *testing.T) {
	f := dmHarness(t)
	bob := f.bob.ID.String()
	msg, file := f.sendFile("alice", bob, 500)
	keptID := f.must("dm_keep", f.bob, map[string]any{"message": msg})["kept"].(map[string]any)[file].(string)

	// The kept record goes first: the sender's file and the bytes are untouched.
	key := f.storageKey(file)
	f.must("storage_delete", f.bob, map[string]any{"kind": "kept", "files": []string{keptID}})
	if !f.bytesExist(key) {
		t.Fatal("removing a kept record deleted the sender's bytes")
	}
	if _, err := f.call("file_download", f.alice, map[string]any{"file": file}); err != nil {
		t.Fatalf("alice lost her file when bob removed his record: %v", err)
	}
	// And he can keep it again while the message is there.
	f.must("dm_keep", f.bob, map[string]any{"message": msg})
}

func TestKeepingNeedsRoomAndARealMessage(t *testing.T) {
	f := dmHarness(t)
	bob := f.bob.ID.String()
	msg, _ := f.sendFile("alice", bob, 800)

	f.s.StorageLimit = func(context.Context) int64 { return 500 }
	if _, err := f.call("dm_keep", f.bob, map[string]any{"message": msg}); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("kept over the limit: %v", err)
	}
	f.s.StorageLimit = nil

	// A message with no files, a deleted one, or another file's id.
	plain := f.must("dm_send", f.alice, map[string]any{"to": bob, "body": "hi"})["id"].(string)
	if _, err := f.call("dm_keep", f.bob, map[string]any{"message": plain}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("kept a message with no files: %v", err)
	}
	if _, err := f.call("dm_keep", f.bob, map[string]any{"message": msg, "file": "00000000000000010000000000000099"}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("kept a file that isn't in the message: %v", err)
	}
	f.must("dm_unsend", f.alice, map[string]any{"id": msg})
	if _, err := f.call("dm_keep", f.bob, map[string]any{"message": msg}); err == nil {
		t.Fatal("kept a deleted message's file")
	}
}

func (f *dmFixture) storageKey(fileID string) string {
	f.t.Helper()
	id, err := identity.Parse(fileID)
	if err != nil {
		f.t.Fatal(err)
	}
	var row filedata.File
	if err := f.s.R.Get(f.ctx, "files", id, &row); err != nil {
		return ""
	}
	return row.StorageKey
}

func (f *dmFixture) bytesExist(key string) bool {
	f.t.Helper()
	ok, err := f.s.K.FS().Exists(f.ctx, key)
	if err != nil {
		f.t.Fatal(err)
	}
	return ok
}
