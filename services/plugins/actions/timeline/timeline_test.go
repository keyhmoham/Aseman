package timeline

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
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

func (fakeKernel) Env() map[string]string { return map[string]string{} }

func harness(t *testing.T) (*Service, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range append(dbmodel.Models(), Models()...) {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	return NewService(fakeKernel{}, &repo.Repo{DB: db}, logger.Global()), ctx
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


func summaries(t *testing.T, s *Service, ctx context.Context, space string) map[string]bool {
	t.Helper()
	got, err := s.Search(ctx, space, SearchQuery{Limit: 100})
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]bool{}
	for _, e := range got {
		for _, line := range strings.Split(e.Summary, "; ") {
			out[line] = true
		}
	}
	return out
}

// has reports whether a line starts with want (qualifiers follow in parentheses).
func has(lines map[string]bool, want string) bool {
	for l := range lines {
		if l == want || strings.HasPrefix(l, want+" (") {
			return true
		}
	}
	return false
}

func TestFeedsWriteEachSpaceEventOnce(t *testing.T) {
	s, ctx := harness(t)
	now := time.Now().UTC().Truncate(time.Second)
	seed(t, s, ctx, now)
	if err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	got := summaries(t, s, ctx, spaceA)
	for _, want := range []string{
		"@ann asked for request (#turn1)",
		"request (#turn1) was asked in general (#00a002)",
		"request (#turn1) has status: done",
		"Coder (#000c0d) ran tool: sandbox_exec",
		"Coder (#000c0d) ran tool: message_send",
		"@ann posted in general (#00a002)",
		"Coder (#000c0d) logged work in general (#00a002)",
		"Coder (#000c0d) shared file landing.html (#file1)",
		"general (#00a002) was opened in Launch (#00a001)",
	} {
		if !has(got, want) {
			t.Errorf("missing %q in %v", want, got)
		}
	}
	if has(got, "Coder (#000c0d) ran tool: file_send") {
		t.Error("a running tool was written before it finished")
	}

	// Nothing new: nothing is written again.
	n, _ := s.R.Count(ctx, entriesTable, dbFilter())
	if err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	if m, _ := s.R.Count(ctx, entriesTable, dbFilter()); m != n {
		t.Fatalf("a second pass wrote %d more entries", m-n)
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
	s.written = map[string]bool{} // as after a restart
	if err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	if !has(summaries(t, s, ctx, spaceA), "Coder (#000c0d) ran tool: file_send") {
		t.Fatal("the finished tool run never reached the timeline")
	}
}

func TestSearchFiltersByWordsKindsAndTime(t *testing.T) {
	s, ctx := harness(t)
	now := time.Now().UTC().Truncate(time.Second)
	seed(t, s, ctx, now)
	if err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	hits, err := s.Search(ctx, spaceA, SearchQuery{Query: "landing.html shared"})
	if err != nil || len(hits) != 1 || !strings.Contains(hits[0].Summary, "shared file landing.html") {
		t.Fatalf("word search = %+v, %v", hits, err)
	}
	all, _ := s.Search(ctx, spaceA, SearchQuery{Limit: 100})
	kind := hits[0].Kind
	byKind, _ := s.Search(ctx, spaceA, SearchQuery{Kinds: []string{kind}, Limit: 100})
	if len(byKind) == 0 || len(byKind) >= len(all) {
		t.Fatalf("kind %q filter: %d of %d", kind, len(byKind), len(all))
	}
	for _, e := range byKind {
		if e.Kind != kind {
			t.Fatalf("kind filter let %q through", e.Kind)
		}
	}
	recent, _ := s.Search(ctx, spaceA, SearchQuery{Since: now.Add(-5*time.Minute - time.Second), Limit: 100})
	for _, e := range recent {
		if e.At.Before(now.Add(-5*time.Minute - time.Second)) {
			t.Fatalf("since filter let %v through", e.At)
		}
	}
	if len(recent) == 0 || len(recent) >= len(all) {
		t.Fatalf("since filter: %d of %d", len(recent), len(all))
	}
	// Newest first.
	for i := 1; i < len(all); i++ {
		if all[i].At.After(all[i-1].At) {
			t.Fatal("search is not newest first")
		}
	}
}

func TestAgentsReadOnlyTheirSpaceTimeline(t *testing.T) {
	s, ctx := harness(t)
	seed(t, s, ctx, time.Now().UTC())
	if err := s.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.Search(ctx, spaceB, SearchQuery{}); len(got) != 0 {
		t.Fatalf("space B reads space A's entries: %+v", got)
	}
	a, _ := s.Search(ctx, spaceA, SearchQuery{Limit: 1})
	if len(a) != 1 {
		t.Fatal("space A has no entries")
	}
	view, err := s.Entry(ctx, spaceA, a[0].ID)
	if err != nil || view.Entry.ID != a[0].ID || len(view.Before) == 0 {
		t.Fatalf("entry = %+v, %v", view, err)
	}
	if _, err := s.Entry(ctx, spaceB, a[0].ID); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("another space's entry = %v", err)
	}
	if _, err := s.Search(ctx, "", SearchQuery{}); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("no space = %v", err)
	}
}

func TestOffSwitch(t *testing.T) {
	t.Setenv(EnvSwitch, "off")
	s, ctx := harness(t)
	if on, _ := s.Enabled(ctx); on {
		t.Fatal("timelines are on")
	}
	if _, err := s.Search(ctx, spaceA, SearchQuery{}); errs.CodeOf(err) != errs.CodeUnavailable {
		t.Fatalf("search while off = %v", err)
	}
}

func dbFilter() database.Filter { return database.Filter{} }
