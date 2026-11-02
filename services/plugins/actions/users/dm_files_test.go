package users

import (
	"context"
	"encoding/base64"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
)

func (f *dmFixture) upload(from, to string, name, mime string, size int) map[string]any {
	f.t.Helper()
	caller := f.alice
	if from == "bob" {
		caller = f.bob
	}
	return f.must("dm_file_upload", caller, map[string]any{"to": to, "name": name, "mime": mime, "data": base64.StdEncoding.EncodeToString([]byte(strings.Repeat("x", size)))})
}

func TestSendingAFileInAChat(t *testing.T) {
	f := dmHarness(t)
	alice, bob := f.alice.ID.String(), f.bob.ID.String()

	photo := f.upload("alice", bob, "cat.png", "image/png", 2000)
	id := photo["file_id"].(string)
	if photo["size"] != float64(2000) || photo["content_url"] != "/v1/files/"+id+"/content" {
		t.Fatalf("upload = %v", photo)
	}

	// Not yet sent: the other person can't open it; an outsider never can.
	if _, err := f.call("file_download", f.bob, map[string]any{"file": id}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("bob opened an unsent file: %v", err)
	}
	// Nobody else can put it in their message.
	if _, err := f.call("dm_send", f.bob, map[string]any{"to": alice, "attachments": []string{id}}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("bob sent alice's file: %v", err)
	}

	// A message may be only a file.
	sent := f.must("dm_send", f.alice, map[string]any{"to": bob, "body": "", "attachments": []string{id}})
	if sent["ok"] != true {
		t.Fatalf("send = %v", sent)
	}
	for _, c := range []struct {
		who  string
		peer string
	}{{"alice", bob}, {"bob", alice}} {
		caller := f.alice
		if c.who == "bob" {
			caller = f.bob
		}
		m := firstMessage(f.must("dm_list", caller, map[string]any{"peer": c.peer}))
		atts, _ := m["attachments"].([]any)
		if len(atts) != 1 || atts[0].(map[string]any)["name"] != "cat.png" || m["body"] != "" {
			t.Fatalf("%s sees %v", c.who, m)
		}
	}
	// Now bob may open it; a file can't go in two messages.
	if _, err := f.call("file_download", f.bob, map[string]any{"file": id}); err != nil {
		t.Fatalf("bob can't open a file sent to him: %v", err)
	}
	if _, err := f.call("dm_send", f.alice, map[string]any{"to": bob, "attachments": []string{id}}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a file went into two messages: %v", err)
	}
	// The thread preview carries it too.
	threads := f.must("dm_threads", f.bob, nil)["threads"].([]any)
	if last := threads[0].(map[string]any)["last"].(map[string]any); len(last["attachments"].([]any)) != 1 {
		t.Fatalf("thread last = %v", last)
	}
}

func TestFilesCountAgainstTheSender(t *testing.T) {
	f := dmHarness(t)
	bob := f.bob.ID.String()
	a := f.upload("alice", bob, "a.bin", "application/octet-stream", 1000)["file_id"].(string)
	b := f.upload("alice", bob, "b.bin", "application/octet-stream", 500)["file_id"].(string)
	f.must("dm_send", f.alice, map[string]any{"to": bob, "body": "two files", "attachments": []string{a, b}})

	use := f.must("storage_usage", f.alice, nil)
	if use["used_bytes"] != float64(1500) || use["chats_bytes"] != float64(1500) || use["files"] != float64(2) || use["limit_bytes"] != float64(0) {
		t.Fatalf("alice uses %v", use)
	}
	if got := f.must("storage_usage", f.bob, nil)["used_bytes"]; got != float64(0) {
		t.Fatalf("the receiver is charged: %v", got)
	}

	// Taking the message back deletes the files and gives the storage back.
	id := firstMessage(f.must("dm_list", f.alice, map[string]any{"peer": bob}))["id"].(string)
	f.must("dm_unsend", f.alice, map[string]any{"id": id})
	if got := f.must("storage_usage", f.alice, nil)["used_bytes"]; got != float64(0) {
		t.Fatalf("after unsend alice still uses %v", got)
	}
	if _, err := f.call("file_download", f.alice, map[string]any{"file": a}); err == nil {
		t.Fatal("the file is still there after unsend")
	}
}

func TestStorageLimitAndUploadRules(t *testing.T) {
	f := dmHarness(t)
	bob := f.bob.ID.String()

	f.s.StorageLimit = func(context.Context) int64 { return 1500 }
	f.upload("alice", bob, "one.bin", "", 1000)
	if _, err := f.call("dm_file_upload", f.alice, map[string]any{"to": bob, "name": "two.bin", "data": base64.StdEncoding.EncodeToString([]byte(strings.Repeat("x", 600)))}); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("over the limit: %v", err)
	}
	f.s.StorageLimit = nil

	big := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("x", maxDirectFile+1)))
	if _, err := f.call("dm_file_upload", f.alice, map[string]any{"to": bob, "name": "big.bin", "data": big}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("too large: %v", err)
	}
	if _, err := f.call("dm_file_upload", f.alice, map[string]any{"to": bob, "name": "", "data": "eA=="}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("no name: %v", err)
	}
	// A blocked person can't be sent files.
	f.must("dm_block", f.bob, map[string]any{"peer": f.alice.ID.String()})
	if _, err := f.call("dm_file_upload", f.alice, map[string]any{"to": bob, "name": "x.bin", "data": "eA=="}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("blocked: %v", err)
	}
	// An empty message with nothing attached is still refused.
	if _, err := f.call("dm_send", f.alice, map[string]any{"to": f.alice.ID.String(), "body": ""}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("empty message: %v", err)
	}
}

func TestAVoiceMessageCarriesItsLength(t *testing.T) {
	f := dmHarness(t)
	bob := f.bob.ID.String()
	data := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("x", 3000)))

	up := f.must("dm_file_upload", f.alice, map[string]any{"to": bob, "name": "voice.m4a", "mime": "audio/mp4", "data": data, "voice": true, "duration_ms": 7400})
	if up["voice"] != true || up["duration_ms"] != float64(7400) {
		t.Fatalf("upload = %v", up)
	}
	f.must("dm_send", f.alice, map[string]any{"to": bob, "attachments": []string{up["file_id"].(string)}})
	for _, c := range []struct {
		who  string
		peer string
	}{{"bob", f.alice.ID.String()}, {"alice", bob}} {
		caller := f.bob
		if c.who == "alice" {
			caller = f.alice
		}
		att := firstMessage(f.must("dm_list", caller, map[string]any{"peer": c.peer}))["attachments"].([]any)[0].(map[string]any)
		if att["voice"] != true || att["duration_ms"] != float64(7400) {
			t.Fatalf("%s sees %v", c.who, att)
		}
	}

	// A made-up length is bounded; an ordinary audio file is not a voice message; a voice message must be audio.
	long := f.must("dm_file_upload", f.alice, map[string]any{"to": bob, "name": "v.m4a", "mime": "audio/mp4", "data": data, "voice": true, "duration_ms": 99999999999})
	if long["duration_ms"] != float64(maxVoiceMS) {
		t.Fatalf("length = %v", long["duration_ms"])
	}
	song := f.must("dm_file_upload", f.alice, map[string]any{"to": bob, "name": "song.mp3", "mime": "audio/mpeg", "data": data})
	if song["voice"] != nil {
		t.Fatalf("a picked audio file became a voice message: %v", song)
	}
	if _, err := f.call("dm_file_upload", f.alice, map[string]any{"to": bob, "name": "x.png", "mime": "image/png", "data": data, "voice": true}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("a picture as a voice message: %v", err)
	}
}

func TestAVoiceMessageCarriesItsSoundWave(t *testing.T) {
	f := dmHarness(t)
	bob := f.bob.ID.String()
	data := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("x", 2000)))

	up := f.must("dm_file_upload", f.alice, map[string]any{"to": bob, "name": "v.m4a", "mime": "audio/mp4", "data": data, "voice": true, "duration_ms": 3000, "waveform": []int{10, 55, 100, 300, -5, 40}})
	wave := up["waveform"].([]any)
	if len(wave) != 6 || wave[3] != float64(100) || wave[4] != float64(0) {
		t.Fatalf("wave = %v (out-of-range bars must be clamped to 0-100)", wave)
	}
	f.must("dm_send", f.alice, map[string]any{"to": bob, "attachments": []string{up["file_id"].(string)}})
	att := firstMessage(f.must("dm_list", f.bob, map[string]any{"peer": f.alice.ID.String()}))["attachments"].([]any)[0].(map[string]any)
	if len(att["waveform"].([]any)) != 6 {
		t.Fatalf("bob sees %v", att)
	}

	// Too many bars are cut; no wave and a plain audio file carry none.
	many := make([]int, 500)
	long := f.must("dm_file_upload", f.alice, map[string]any{"to": bob, "name": "v.m4a", "mime": "audio/mp4", "data": data, "voice": true, "waveform": many})
	if len(long["waveform"].([]any)) != maxWaveformBars {
		t.Fatalf("bars = %d", len(long["waveform"].([]any)))
	}
	none := f.must("dm_file_upload", f.alice, map[string]any{"to": bob, "name": "v.m4a", "mime": "audio/mp4", "data": data, "voice": true})
	song := f.must("dm_file_upload", f.alice, map[string]any{"to": bob, "name": "s.mp3", "mime": "audio/mpeg", "data": data, "waveform": []int{1, 2}})
	if none["waveform"] != nil || song["waveform"] != nil {
		t.Fatalf("none=%v song=%v", none["waveform"], song["waveform"])
	}
}

func TestFileDownloadNeedsSignInAndAccess(t *testing.T) {
	f := dmHarness(t)
	bob := f.bob.ID.String()
	id := f.upload("alice", bob, "secret.bin", "application/octet-stream", 100)["file_id"].(string)
	f.must("dm_send", f.alice, map[string]any{"to": bob, "attachments": []string{id}})

	// Knowing a file's id is not enough: not signed in, or not someone it was shared with.
	if _, err := f.call("file_download", api.Caller{}, map[string]any{"file": id}); err == nil {
		t.Fatal("an anonymous caller downloaded a file")
	}
	stranger := api.Caller{ID: mustID(t, "00000000000000010000000000000099"), Kind: "user"}
	if _, err := f.call("file_download", stranger, map[string]any{"file": id}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("a stranger downloaded it: %v", err)
	}
	// The sender and the person it was sent to may.
	for _, who := range []api.Caller{f.alice, f.bob} {
		if _, err := f.call("file_download", who, map[string]any{"file": id}); err != nil {
			t.Fatalf("%v could not download: %v", who.ID, err)
		}
	}
	// With no way to ask the file server's rule, nobody gets it (closed, not open).
	f.s.FileAccess = nil
	f.s.K = nil
	if _, err := f.call("file_download", f.alice, map[string]any{"file": id}); err == nil {
		t.Fatal("a download went through with no access rule")
	}
}
