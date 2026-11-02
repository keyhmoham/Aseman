package users

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
)

func TestACallRingsIsAnsweredAndEnds(t *testing.T) {
	f := dmHarness(t)
	f.openCalls()
	bob := f.bob.ID.String()
	out := f.must("call_start", f.alice, map[string]any{"to": bob, "video": true})
	call := out["call"].(map[string]any)
	id := call["id"].(string)
	if call["state"] != "ringing" || call["video"] != true {
		t.Fatalf("call = %v", call)
	}
	if servers := out["ice_servers"].([]any); len(servers) == 0 {
		t.Fatal("no ice servers: STUN at least is always offered")
	}

	// Bob is rung; Alice is not (it is her own call).
	in := f.must("call_incoming", f.bob, nil)
	if in["call"] == nil || in["call"].(map[string]any)["id"] != id || in["caller"] == nil {
		t.Fatalf("bob's incoming = %v", in)
	}
	if f.must("call_incoming", f.alice, nil)["call"] != nil {
		t.Fatal("the caller is not rung for their own call")
	}
	// A second call to someone busy is refused, as is a call from someone in one.
	if _, err := f.call("call_start", f.alice, map[string]any{"to": bob}); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("second call: %v", err)
	}

	// Setup messages: only the right side may send each; the other side reads them.
	f.must("call_signal", f.alice, map[string]any{"id": id, "kind": "offer", "payload": "v=0 offer"})
	if _, err := f.call("call_signal", f.bob, map[string]any{"id": id, "kind": "offer", "payload": "x"}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("callee made an offer: %v", err)
	}
	f.must("call_signal", f.alice, map[string]any{"id": id, "kind": "ice", "payload": "{candidate}"})
	got := f.must("call_poll", f.bob, map[string]any{"id": id})["signals"].([]any)
	if len(got) != 2 || got[0].(map[string]any)["kind"] != "offer" {
		t.Fatalf("bob reads %v", got)
	}
	if own := f.must("call_poll", f.alice, map[string]any{"id": id})["signals"].([]any); len(own) != 0 {
		t.Fatalf("alice reads her own signals back: %v", own)
	}

	if _, err := f.call("call_accept", f.alice, map[string]any{"id": id}); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("caller answered their own call: %v", err)
	}
	acc := f.must("call_accept", f.bob, map[string]any{"id": id})
	if acc["call"].(map[string]any)["state"] != "active" || len(acc["ice_servers"].([]any)) == 0 {
		t.Fatalf("accept = %v", acc)
	}
	f.must("call_signal", f.bob, map[string]any{"id": id, "kind": "answer", "payload": "v=0 answer"})
	if a := f.must("call_poll", f.alice, map[string]any{"id": id})["signals"].([]any); len(a) != 1 || a[0].(map[string]any)["kind"] != "answer" {
		t.Fatalf("alice reads %v", a)
	}

	end := f.must("call_end", f.bob, map[string]any{"id": id})["call"].(map[string]any)
	if end["state"] != "ended" || end["end_reason"] != "hangup" {
		t.Fatalf("end = %v", end)
	}
	if _, err := f.call("call_signal", f.alice, map[string]any{"id": id, "kind": "ice", "payload": "late"}); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("signal after the end: %v", err)
	}
	// Both are free to call again.
	f.must("call_start", f.bob, map[string]any{"to": f.alice.ID.String()})
}

func TestACallDeclinedCancelledOrMissed(t *testing.T) {
	f := dmHarness(t)
	f.openCalls()
	alice, bob := f.alice.ID.String(), f.bob.ID.String()

	id := f.must("call_start", f.alice, map[string]any{"to": bob})["call"].(map[string]any)["id"].(string)
	if d := f.must("call_decline", f.bob, map[string]any{"id": id})["call"].(map[string]any); d["end_reason"] != "declined" {
		t.Fatalf("decline = %v", d)
	}

	id = f.must("call_start", f.bob, map[string]any{"to": alice})["call"].(map[string]any)["id"].(string)
	if c := f.must("call_end", f.bob, map[string]any{"id": id})["call"].(map[string]any); c["end_reason"] != "cancelled" {
		t.Fatalf("cancel = %v", c)
	}

	// Nobody answers: the call is missed once it has rung out.
	old := ringFor
	ringFor = 10 * time.Millisecond
	defer func() { ringFor = old }()
	id = f.must("call_start", f.alice, map[string]any{"to": bob})["call"].(map[string]any)["id"].(string)
	time.Sleep(30 * time.Millisecond)
	if m := f.must("call_poll", f.bob, map[string]any{"id": id})["call"].(map[string]any); m["state"] != "ended" || m["end_reason"] != "missed" {
		t.Fatalf("missed = %v", m)
	}
	if f.must("call_incoming", f.bob, nil)["call"] != nil {
		t.Fatal("a missed call keeps ringing")
	}
}

func TestCallingYourselfOrABlockedPersonIsRefused(t *testing.T) {
	f := dmHarness(t)
	f.openCalls()
	if _, err := f.call("call_start", f.alice, map[string]any{"to": f.alice.ID.String()}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("self call: %v", err)
	}
	f.must("dm_block", f.bob, map[string]any{"peer": f.alice.ID.String()})
	if _, err := f.call("call_start", f.alice, map[string]any{"to": f.bob.ID.String()}); errs.CodeOf(err) != errs.CodeConflict {
		t.Fatalf("blocked call: %v", err)
	}
}

func TestTurnProviders(t *testing.T) {
	// coturn's REST credentials: the user is the expiry, the password an HMAC of it.
	now := time.Unix(1_700_000_000, 0)
	got := coturnICE([]string{"turn:turn.example.com:3478", " "}, "s3cret", time.Hour, now)
	if len(got) != 1 || got[0].Username != "1700003600" || got[0].Credential == "" || len(got[0].URLs) != 1 {
		t.Fatalf("coturn = %+v", got)
	}
	if coturnICE(nil, "s3cret", time.Hour, now) != nil || coturnICE([]string{"turn:x"}, "", time.Hour, now) != nil {
		t.Fatal("coturn without urls or a secret issues nothing")
	}

	// Cloudflare: the list form and the single-server form both parse; a failure is an error.
	for name, body := range map[string]string{
		"list":   `{"iceServers":[{"urls":["stun:stun.cloudflare.com:3478"]},{"urls":["turn:turn.cloudflare.com:3478"],"username":"u","credential":"c"}]}`,
		"single": `{"iceServers":{"urls":["turn:turn.cloudflare.com:3478"],"username":"u","credential":"c"}}`,
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("Authorization") != "Bearer tok" || !strings.HasSuffix(r.URL.Path, "/turn/keys/key1/credentials/generate-ice-servers") {
				http.Error(w, "no", http.StatusUnauthorized)
				return
			}
			var in map[string]any
			_ = json.NewDecoder(r.Body).Decode(&in)
			if in["ttl"] != float64(3600) {
				http.Error(w, "ttl", http.StatusBadRequest)
				return
			}
			_, _ = w.Write([]byte(body))
		}))
		old := cloudflareAPI
		cloudflareAPI = srv.URL
		servers, err := cloudflareICE(context.Background(), "key1", "tok", time.Hour)
		if err != nil || servers[len(servers)-1].Username != "u" {
			t.Fatalf("%s: %+v %v", name, servers, err)
		}
		if _, err := cloudflareICE(context.Background(), "key1", "wrong", time.Hour); err == nil {
			t.Fatalf("%s: a rejected token must be an error", name)
		}
		cloudflareAPI = old
		srv.Close()
	}
	if _, err := cloudflareICE(context.Background(), "", "", time.Hour); err == nil {
		t.Fatal("unconfigured cloudflare must be an error")
	}

	// Nothing configured: STUN only, so direct calls still work.
	t.Setenv("ASEMAN_TURN_CF_KEY_ID", "")
	t.Setenv("ASEMAN_TURN_URLS", "")
	f := dmHarness(t)
	if servers := f.s.iceServers(context.Background()); len(servers) != 1 || servers[0].Username != "" {
		t.Fatalf("fallback = %+v", servers)
	}
}

func TestCameraStateTravelsToTheOtherSide(t *testing.T) {
	f := dmHarness(t)
	f.openCalls()
	id := f.must("call_start", f.alice, map[string]any{"to": f.bob.ID.String(), "video": true})["call"].(map[string]any)["id"].(string)
	f.must("call_accept", f.bob, map[string]any{"id": id})
	f.must("call_signal", f.bob, map[string]any{"id": id, "kind": "state", "payload": `{"camera":false,"muted":true}`})
	got := f.must("call_poll", f.alice, map[string]any{"id": id})["signals"].([]any)
	if len(got) != 1 || got[0].(map[string]any)["kind"] != "state" {
		t.Fatalf("alice reads %v", got)
	}
	if _, err := f.call("call_signal", f.bob, map[string]any{"id": id, "kind": "nonsense", "payload": "x"}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("unknown kind: %v", err)
	}
}

func TestFinishedCallsAreInTheChat(t *testing.T) {
	f := dmHarness(t)
	f.openCalls()
	alice, bob := f.alice.ID.String(), f.bob.ID.String()

	// One answered video call, one declined voice call.
	id := f.must("call_start", f.alice, map[string]any{"to": bob, "video": true})["call"].(map[string]any)["id"].(string)
	f.must("call_accept", f.bob, map[string]any{"id": id})
	time.Sleep(5 * time.Millisecond)
	f.must("call_end", f.alice, map[string]any{"id": id})
	id2 := f.must("call_start", f.bob, map[string]any{"to": alice})["call"].(map[string]any)["id"].(string)
	f.must("call_decline", f.alice, map[string]any{"id": id2})
	// One still ringing is not history yet.
	f.must("call_start", f.alice, map[string]any{"to": bob})

	for _, who := range []struct {
		c    api.Caller
		peer string
	}{{f.alice, bob}, {f.bob, alice}} {
		calls := f.must("dm_list", who.c, map[string]any{"peer": who.peer})["calls"].([]any)
		if len(calls) != 2 {
			t.Fatalf("calls = %v", calls)
		}
		newest := calls[0].(map[string]any)
		if newest["end_reason"] != "declined" || newest["video"] == true {
			t.Fatalf("newest = %v", newest)
		}
		answered := calls[1].(map[string]any)
		if answered["answered_at"] == nil || answered["ended_at"] == nil || answered["video"] != true {
			t.Fatalf("answered = %v", answered)
		}
	}

	// Deleting the chat clears its calls for that person only.
	f.must("dm_delete", f.alice, map[string]any{"peer": bob})
	if n := len(f.must("dm_list", f.alice, map[string]any{"peer": bob})["calls"].([]any)); n != 0 {
		t.Fatalf("alice still sees %d calls", n)
	}
	if n := len(f.must("dm_list", f.bob, map[string]any{"peer": alice})["calls"].([]any)); n != 2 {
		t.Fatalf("bob sees %d calls", n)
	}
}

// openCalls lets both people be called by anyone, as the call tests are not about privacy.
func (f *dmFixture) openCalls() {
	f.t.Helper()
	for _, who := range []api.Caller{f.alice, f.bob} {
		f.must("privacy_set", who, map[string]any{"calls_voice": "everyone", "calls_video": "everyone"})
	}
}
