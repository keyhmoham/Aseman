package timeline

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

const (
	spaceA = "0000000000000001000000000000a001"
	spaceB = "0000000000000001000000000000b001"
	roomA  = "0000000000000001000000000000a002"
	ann    = "00000000000000010000000000000a11"
	coder  = "00000000000000010000000000000c0d" // the agent's bot
	coderA = "00000000000000010000000000000c0a" // its account
)

type fakeKernel struct{}

func (fakeKernel) Env() map[string]string {
	return map[string]string{"node_private_key": "test-node-key"}
}

// fakeUtopia answers the parts of Utopia's API the node uses.
type fakeUtopia struct {
	mu         sync.Mutex
	registered bool
	kbs        map[string]string // kb → source
	sources    map[string]string // source → push key
	items      map[string][]observation
	mcp        []map[string]any
	token      string
	srv        *httptest.Server
	// wipeAt: when this many items have been pushed, the next push finds
	// Utopia's data gone (0: never).
	wipeAt int
}

func newFakeUtopia(t *testing.T) *fakeUtopia {
	u := &fakeUtopia{kbs: map[string]string{}, sources: map[string]string{}, items: map[string][]observation{}}
	u.srv = httptest.NewServer(http.HandlerFunc(u.serve))
	t.Cleanup(u.srv.Close)
	return u
}

func (u *fakeUtopia) serve(w http.ResponseWriter, r *http.Request) {
	u.mu.Lock()
	defer u.mu.Unlock()
	body, _ := io.ReadAll(r.Body)
	auth := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	reply := func(status int, v any) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(v)
	}
	path := strings.TrimPrefix(r.URL.Path, "/api/v1")
	parts := strings.Split(strings.Trim(path, "/"), "/")
	switch {
	case path == "/auth/login":
		if !u.registered {
			reply(401, map[string]any{"error": "invalid credentials"})
			return
		}
		reply(200, map[string]any{"token": "jwt"})
	case path == "/auth/register":
		u.registered = true
		reply(200, map[string]any{"token": "jwt"})
	case path == "/workspaces":
		reply(200, []map[string]any{{"id": "ws1"}})
	case len(parts) == 3 && parts[0] == "workspaces" && parts[2] == "kbs":
		id := fmt.Sprintf("kb%d", len(u.kbs)+1)
		u.kbs[id] = ""
		reply(200, map[string]any{"id": id})
	case len(parts) == 3 && parts[0] == "kbs" && parts[2] == "sources":
		id := "src-" + parts[1]
		u.kbs[parts[1]] = id
		u.sources[id] = "push-" + parts[1]
		reply(200, map[string]any{"source": map[string]any{"id": id}, "ingest_token": "push-" + parts[1]})
	case path == "/me/tokens":
		u.token = "utp_pat_read"
		reply(200, map[string]any{"token": u.token})
	case len(parts) == 3 && parts[0] == "sources" && parts[2] == "statements":
		key, ok := u.sources[parts[1]]
		if !ok {
			reply(404, map[string]any{"error": "Not found"})
			return
		}
		if auth != key {
			reply(401, map[string]any{"error": "bad key"})
			return
		}
		if u.wipeAt > 0 && u.countLocked() >= u.wipeAt {
			u.wipeAt = 0
			u.kbs, u.sources, u.items, u.token = map[string]string{}, map[string]string{}, map[string][]observation{}, ""
			reply(404, map[string]any{"error": "Not found"})
			return
		}
		var o observation
		_ = json.Unmarshal(body, &o)
		u.items[parts[1]] = append(u.items[parts[1]], o)
		reply(200, map[string]any{"action": "created"})
	case len(parts) == 3 && parts[0] == "kbs" && parts[2] == "mcp":
		if auth != u.token || u.token == "" {
			reply(401, map[string]any{"error": "bad token"})
			return
		}
		var msg map[string]any
		_ = json.Unmarshal(body, &msg)
		msg["kb"] = parts[1]
		u.mcp = append(u.mcp, msg)
		if msg["method"] == "tools/list" {
			reply(200, map[string]any{"jsonrpc": "2.0", "id": msg["id"], "result": map[string]any{"tools": []any{
				map[string]any{"name": "timeline"}, map[string]any{"name": "changes"}, map[string]any{"name": "remember"}}}})
			return
		}
		reply(200, map[string]any{"jsonrpc": "2.0", "id": msg["id"], "result": map[string]any{
			"content": []any{map[string]any{"type": "text", "text": "from " + parts[1]}}}})
	default:
		reply(404, map[string]any{"error": "Not found"})
	}
}

// pushed is every statement the fake received, as "subject|phrase|object|value".
func (u *fakeUtopia) pushed() map[string]bool {
	u.mu.Lock()
	defer u.mu.Unlock()
	out := map[string]bool{}
	for _, items := range u.items {
		for _, o := range items {
			for _, s := range o.S {
				out[fmt.Sprintf("%v|%v|%v|%v", s[1], s[2], s[3], s[4])] = true
			}
		}
	}
	return out
}

func (u *fakeUtopia) count() int {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.countLocked()
}

func (u *fakeUtopia) countLocked() int {
	n := 0
	for _, items := range u.items {
		n += len(items)
	}
	return n
}

func harness(t *testing.T) (*Service, *fakeUtopia, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range append(dbmodel.Models(), Models()...) {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	u := newFakeUtopia(t)
	t.Setenv(EnvURL, u.srv.URL)
	t.Setenv(EnvPassword, "secret-password")
	s := NewService(fakeKernel{}, &repo.Repo{DB: db}, logger.Global())
	return s, u, ctx
}

func create(t *testing.T, s *Service, ctx context.Context, model, id string, v map[string]any) {
	t.Helper()
	v["id"] = id
	if err := s.R.DB.Create(ctx, model, id, v); err != nil {
		t.Fatalf("create %s: %v", model, err)
	}
}

func seed(t *testing.T, s *Service, ctx context.Context, now time.Time) {
	at := func(m int) time.Time { return now.Add(time.Duration(m) * time.Minute) }
	create(t, s, ctx, "spaces", spaceA, map[string]any{"name": "Launch", "created_at": at(-60)})
	create(t, s, ctx, "rooms", roomA, map[string]any{"space_id": spaceA, "name": "general", "created_at": at(-50)})
	create(t, s, ctx, "accounts", ann, map[string]any{"handle": "ann", "kind": "user", "created_at": at(-60)})
	create(t, s, ctx, "accounts", coderA, map[string]any{"handle": "coder-x", "kind": "bot", "created_at": at(-60)})
	create(t, s, ctx, "bots", coder, map[string]any{"name": "Coder", "account_id": coderA, "kind": "agent", "created_at": at(-60)})
	create(t, s, ctx, "room_turns", "turn1", map[string]any{"space_id": spaceA, "room_id": roomA, "actor_id": ann,
		"prompt": "ship the landing page", "status": "done", "created_at": at(-10), "updated_at": at(-5), "ended_at": at(-5)})
	create(t, s, ctx, "execution_events", "ev1", map[string]any{"space_id": spaceA, "room_id": roomA, "run_id": "run1",
		"agent_id": coder, "agent_name": "Coder", "tool": "sandbox_exec", "status": "done", "at": at(-9)})
	create(t, s, ctx, "execution_events", "ev2", map[string]any{"space_id": spaceA, "room_id": roomA, "run_id": "run1",
		"agent_id": coder, "agent_name": "Coder", "tool": "file_send", "status": "running", "at": at(-8)})
	create(t, s, ctx, "execution_events", "ev3", map[string]any{"space_id": spaceA, "room_id": roomA, "run_id": "run1",
		"agent_id": coder, "agent_name": "Coder", "tool": "message_send", "status": "done", "at": at(-7)})
	create(t, s, ctx, "messages", "msg1", map[string]any{"space_id": spaceA, "room_id": roomA, "sender_id": ann,
		"body": "please ship it", "created_at": at(-10)})
	create(t, s, ctx, "messages", "msg2", map[string]any{"space_id": spaceA, "room_id": roomA, "sender_id": coderA,
		"body": "Ran the build: ok", "kind": "log", "created_at": at(-6)})
	create(t, s, ctx, "files", "file1", map[string]any{"space_id": spaceA, "room_id": roomA, "owner_id": coderA,
		"name": "landing.html", "mime": "text/html", "size": int64(1200), "created_at": at(-4)})
}

func TestFeedsPushEachSpaceEventOnce(t *testing.T) {
	s, u, ctx := harness(t)
	now := time.Now().UTC().Truncate(time.Second)
	seed(t, s, ctx, now)
	if err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	got := u.pushed()
	for _, want := range []string{
		"@ann|asked for|request (#turn1)|<nil>",
		"request (#turn1)|was asked in|general (#00a002)|<nil>",
		"request (#turn1)|has status|<nil>|done",
		"Coder (#000c0d)|ran tool|<nil>|sandbox_exec",
		"Coder (#000c0d)|ran tool|<nil>|message_send",
		"@ann|posted in|general (#00a002)|<nil>",
		"Coder (#000c0d)|logged work in|general (#00a002)|<nil>",
		"Coder (#000c0d)|shared file|landing.html (#file1)|<nil>",
		"general (#00a002)|was opened in|Launch (#00a001)|<nil>",
	} {
		if !got[want] {
			t.Errorf("missing %q in %v", want, got)
		}
	}
	if got["Coder (#000c0d)|ran tool|<nil>|file_send"] {
		t.Error("a running tool was pushed before it finished")
	}
	// One base per space, items only in the space's own base.
	if len(u.kbs) != 1 {
		t.Fatalf("bases = %v", u.kbs)
	}

	// Nothing new: nothing is sent again.
	n := u.count()
	if err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	if u.count() != n {
		t.Fatalf("a second pass re-sent %d items", u.count()-n)
	}

	// The running tool finishes: the cursor waited for it.
	var ev toolRow
	if err := s.R.DB.Get(ctx, "execution_events", "ev2", &ev); err != nil {
		t.Fatal(err)
	}
	if err := s.R.DB.Update(ctx, "execution_events", "ev2", map[string]any{"id": "ev2", "space_id": spaceA, "room_id": roomA,
		"run_id": "run1", "agent_id": coder, "agent_name": "Coder", "tool": "file_send", "status": "done", "at": ev.At}); err != nil {
		t.Fatal(err)
	}
	s.pushed = map[string]bool{} // as after a restart
	if err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	if !u.pushed()["Coder (#000c0d)|ran tool|<nil>|file_send"] {
		t.Fatal("the finished tool run never reached the timeline")
	}
}

func TestEveryStatementNamesItsThingsAndTime(t *testing.T) {
	s, u, ctx := harness(t)
	seed(t, s, ctx, time.Now().UTC())
	if err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	for _, items := range u.items {
		for _, o := range items {
			if o.ExternalID == "" || o.DocTime == "" {
				t.Errorf("item without identity or time: %+v", o)
			}
			named := map[any]bool{}
			for _, e := range o.E {
				named[e[0]] = true
			}
			for _, st := range o.S {
				if st[0] != nil || !named[st[1]] || (st[3] != nil && !named[st[3]]) || (st[3] == nil) == (st[4] == nil) {
					t.Errorf("statement breaks the contract: %v (things %v)", st, o.E)
				}
				if _, err := time.Parse(time.RFC3339, fmt.Sprint(st[6])); err != nil {
					t.Errorf("statement without a time: %v", st)
				}
			}
		}
	}
}

func TestAgentsReadOnlyTheirSpaceTimeline(t *testing.T) {
	s, u, ctx := harness(t)
	list, err := s.MCP(ctx, spaceA, []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(list), "remember") || !strings.Contains(string(list), `"timeline"`) {
		t.Fatalf("tools/list = %s", list)
	}
	if _, err := s.MCP(ctx, spaceA, []byte(`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"remember","arguments":{}}}`)); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("remember = %v", err)
	}
	a, err := s.MCP(ctx, spaceA, []byte(`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"changes","arguments":{}}}`))
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.MCP(ctx, spaceB, []byte(`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"changes","arguments":{}}}`))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(a), "from kb1") || !strings.Contains(string(b), "from kb2") {
		t.Fatalf("space A read %s, space B read %s", a, b)
	}
	if _, err := s.MCP(ctx, spaceA, []byte(`{"jsonrpc":"2.0","id":5,"method":"resources/list"}`)); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("resources/list = %v", err)
	}
	_ = u
}

func TestAResetUtopiaIsRefilled(t *testing.T) {
	s, u, ctx := harness(t)
	seed(t, s, ctx, time.Now().UTC())
	if err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	// Utopia loses its data: bases, sources and the read token.
	u.mu.Lock()
	u.kbs, u.sources, u.items, u.token = map[string]string{}, map[string]string{}, map[string][]observation{}, ""
	u.mu.Unlock()
	s.pushed = map[string]bool{}
	create(t, s, ctx, "messages", "msg3", map[string]any{"space_id": spaceA, "room_id": roomA, "sender_id": ann,
		"body": "and the docs", "created_at": time.Now().UTC()})
	if err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	if err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	if !u.pushed()["@ann|asked for|request (#turn1)|<nil>"] {
		t.Fatal("the space's history was not refilled")
	}
	if _, err := s.MCP(ctx, spaceA, []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"changes","arguments":{}}}`)); err != nil {
		t.Fatalf("read after reset: %v", err)
	}
}

func TestOffWithoutUtopia(t *testing.T) {
	t.Setenv(EnvURL, "")
	s := NewService(fakeKernel{}, &repo.Repo{DB: memory.New(logger.Global())}, logger.Global())
	if on, _ := s.Enabled(context.Background()); on {
		t.Fatal("enabled without a Utopia URL")
	}
	if _, err := s.MCP(context.Background(), spaceA, []byte(`{"method":"tools/list"}`)); errs.CodeOf(err) != errs.CodeUnavailable {
		t.Fatalf("MCP = %v", err)
	}
}

func TestAResetInTheMiddleOfAPassLosesNothing(t *testing.T) {
	s, u, ctx := harness(t)
	now := time.Now().UTC()
	seed(t, s, ctx, now)
	if err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	create(t, s, ctx, "messages", "msg3", map[string]any{"space_id": spaceA, "room_id": roomA, "sender_id": ann,
		"body": "first new", "created_at": now.Add(time.Minute)})
	create(t, s, ctx, "messages", "msg4", map[string]any{"space_id": spaceA, "room_id": roomA, "sender_id": ann,
		"body": "second new", "created_at": now.Add(2 * time.Minute)})
	// msg3 reaches the old base, then Utopia's data is gone.
	u.mu.Lock()
	u.wipeAt = u.countLocked() + 1
	u.mu.Unlock()
	for i := 0; i < 3; i++ {
		if err := s.Sync(ctx); err != nil {
			t.Fatal(err)
		}
	}
	var bodies []string
	u.mu.Lock()
	for _, items := range u.items {
		for _, o := range items {
			bodies = append(bodies, o.ExternalID)
		}
	}
	u.mu.Unlock()
	joined := strings.Join(bodies, ",")
	for _, want := range []string{"message:msg1", "message:msg3", "message:msg4", "request:turn1"} {
		if !strings.Contains(joined, want) {
			t.Errorf("%s missing after the reset: %s", want, joined)
		}
	}
}
