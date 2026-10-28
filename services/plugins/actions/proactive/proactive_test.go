package proactive

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	pm "github.com/aseman/aseman/plugins/actions/proactive/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/spaces/models/turn"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

const (
	ownerHex = "00000000000000010000000000000001"
	homeHex  = "00000000000000010000000000000050"
	leadHex  = "00000000000000010000000000000060"
)

type fakeGoogle struct{ connected bool }

func (f *fakeGoogle) Connected(context.Context, string) bool { return f.connected }
func (f *fakeGoogle) SearchMail(context.Context, string, string, int) ([]Mail, error) {
	now := time.Now()
	return []Mail{
		{ID: "a", From: "News <n@x.example>", Subject: "Weekly digest", Date: now, Headers: map[string]string{"List-Unsubscribe": "<x>"}},
		{ID: "b", From: "Priya <p@x.example>", Subject: "Quote by Friday?", Date: now},
	}, nil
}
func (f *fakeGoogle) Events(context.Context, string, time.Time, time.Time, string) ([]Event, error) {
	return []Event{{ID: "e", Summary: "Stand-up", Start: time.Now()}}, nil
}

type fakeSpaces struct {
	mu        sync.Mutex
	asks      []string
	posts     []string
	turns     int
	db        *repo.Repo
	onResearch func(ctx context.Context)
}

func (f *fakeSpaces) HomeSpace(context.Context, identity.ID) (*space.Space, error) {
	id, _ := identity.Parse(homeHex)
	return &space.Space{Entity: entity.Entity{ID: id}, Home: true}, nil
}
func (f *fakeSpaces) GetRoom(context.Context, identity.ID) (*space.Room, error) {
	return &space.Room{Color: "#3b82f6"}, nil
}
func (f *fakeSpaces) AskLead(ctx context.Context, actor, spaceID, roomID identity.ID, submission, body, prompt string, silent bool) (*turn.Turn, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asks = append(f.asks, prompt)
	f.turns++
	id, _ := identity.New(1)
	room, _ := identity.Parse("00000000000000010000000000000070")
	t := &turn.Turn{Entity: entity.Entity{ID: id}, SpaceID: spaceID, RoomID: room, ActorID: actor, Status: "running", MessageID: id.String()}
	if err := f.db.DB.Create(ctx, "room_turns", id.String(), t); err != nil {
		return nil, err
	}
	return t, nil
}
func (f *fakeSpaces) RunBackgroundTask(ctx context.Context, _, _, _ identity.ID, task string) (string, error) {
	if f.onResearch != nil {
		f.onResearch(ctx)
	}
	return "nothing new", nil
}
func (f *fakeSpaces) PostMessage(_ context.Context, _, _, _ identity.ID, body string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.posts = append(f.posts, body)
	return nil
}
func (f *fakeSpaces) AsemanAccount(context.Context) (identity.ID, error) { return identity.Parse(leadHex) }

type fakeLLM struct{ calls int }

func (f *fakeLLM) Complete(_ context.Context, c Completion) (CompletionResult, error) {
	f.calls++
	return CompletionResult{Model: "m1", Text: `{"verdicts":[{"id":"b","verdict":"needs_you","reason":"Priya needs the quote by Friday."}]}`}, nil
}

type fakeUsers struct{ n int }

func (f *fakeUsers) Push(context.Context, []identity.ID, PushNote) { f.n++ }

func harness(t *testing.T) (*Service, *fakeSpaces, *fakeLLM, context.Context) {
	t.Helper()
	db := memory.New(logger.Global())
	ctx := helper.WithInternalAccess(context.Background())
	for _, m := range append(dbmodel.Models(), pm.Models()...) {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global()})
	r := &repo.Repo{DB: db}
	s := NewService(k, r, logger.Global())
	spaces, model := &fakeSpaces{db: r}, &fakeLLM{}
	s.Google, s.Spaces, s.LLM, s.Users = &fakeGoogle{connected: true}, spaces, model, &fakeUsers{}
	owner, _ := identity.Parse(ownerHex)
	if err := db.Create(ctx, "accounts", ownerHex, &account.Account{Entity: entity.Entity{ID: owner}, Kind: account.KindUser, Handle: "sam", Status: account.StatusActive}); err != nil {
		t.Fatal(err)
	}
	return s, spaces, model, ctx
}

func TestSuggestStartAndFollow(t *testing.T) {
	s, spaces, _, ctx := harness(t)
	call := gate.ToolCall{Tool: "offer_task", Args: `{"title":"Reply to Priya","detail":"She wants a quote","reason":"deadline Friday"}`,
		SpaceID: homeHex, ActorID: ownerHex, AgentName: "aseman"}
	if _, err := s.AgentTool(ctx, call); err != nil {
		t.Fatal(err)
	}
	if out, _ := s.AgentTool(ctx, call); !strings.Contains(out, "Already suggested") {
		t.Fatal("the same suggestion is not repeated")
	}
	if _, err := s.AgentTool(ctx, gate.ToolCall{Tool: "offer_task", Args: `{"title":"x"}`, ActorID: leadHex}); err == nil {
		t.Fatal("tasks belong to people")
	}
	owner, _ := identity.Parse(ownerHex)
	tasks, _ := s.Tasks(ctx, owner, "", false)
	if len(tasks) != 1 || tasks[0].Status != pm.StatusSuggested || tasks[0].Color != "" {
		t.Fatalf("%+v", tasks)
	}
	started, err := s.Start(ctx, owner, tasks[0].ID.String())
	if err != nil || started.Status != pm.StatusWorking || started.TurnID == "" {
		t.Fatalf("%+v %v", started, err)
	}
	if !strings.Contains(spaces.asks[0], "[task "+started.ID.String()+"]") {
		t.Fatalf("the lead is told which task it is: %s", spaces.asks[0])
	}
	// The run ends: the task becomes ready for review.
	var tr turn.Turn
	_ = s.R.DB.Get(ctx, "room_turns", started.TurnID, &tr)
	tr.Status = "done"
	_ = s.R.DB.Update(ctx, "room_turns", started.TurnID, &tr)
	s.follow(ctx)
	got, _ := s.task(ctx, owner, started.ID.String())
	if got.Status != pm.StatusReview {
		t.Fatalf("a finished run is ready for review: %s", got.Status)
	}
	// Answering a task that needs input sets it working again.
	if _, err := s.AgentTool(ctx, gate.ToolCall{Tool: "task_update", Args: `{"task":"` + got.ID.String() + `","status":"needs_input","summary":"Which price list?"}`, ActorID: ownerHex}); err != nil {
		t.Fatal(err)
	}
	if again, err := s.Answer(ctx, owner, got.ID.String(), "The wholesale one"); err != nil || again.Status != pm.StatusWorking {
		t.Fatalf("%+v %v", again, err)
	}
	if done, _ := s.SetStatus(ctx, owner, got.ID.String(), pm.StatusResolved); done.Status != pm.StatusResolved {
		t.Fatal("resolve")
	}
}

func TestTriageDecidesOnce(t *testing.T) {
	s, _, model, ctx := harness(t)
	owner, _ := identity.Parse(ownerHex)
	verdicts, undecided, err := s.Triage(ctx, owner, "", 10)
	if err != nil || len(verdicts) != 2 || len(undecided) != 0 {
		t.Fatalf("%+v %v %v", verdicts, undecided, err)
	}
	if _, _, err := s.Triage(ctx, owner, "", 10); err != nil || model.calls != 1 {
		t.Fatalf("a message is decided once: %d model calls", model.calls)
	}
}

func TestBriefOnceADayAfterTheFirst(t *testing.T) {
	s, spaces, _, ctx := harness(t)
	owner, _ := identity.Parse(ownerHex)
	if _, ok, err := s.BriefToday(ctx, owner, "UTC", false); err != nil || ok {
		t.Fatalf("no brief on the first day: %v %v", ok, err)
	}
	s.now = func() time.Time { return time.Now().Add(26 * time.Hour) }
	b, ok, err := s.BriefToday(ctx, owner, "UTC", false)
	if err != nil || !ok || !b.Posted {
		t.Fatalf("%+v %v %v", b, ok, err)
	}
	again, _, _ := s.BriefToday(ctx, owner, "UTC", false)
	if again.ID != b.ID || len(spaces.posts) != 1 {
		t.Fatalf("one brief a day, however many ask: %d posts", len(spaces.posts))
	}
	if !strings.Contains(spaces.posts[0], "Priya needs the quote by Friday.") || !strings.Contains(spaces.posts[0], "Stand-up") {
		t.Fatalf("the brief says what needs you and today's calendar: %s", spaces.posts[0])
	}
}

func TestFirstDayRunsOnce(t *testing.T) {
	s, spaces, _, ctx := harness(t)
	owner, _ := identity.Parse(ownerHex)
	out, err := s.FirstDay(ctx, owner, "UTC")
	if err != nil || out["started"] != true {
		t.Fatalf("%v %v", out, err)
	}
	if out, _ = s.FirstDay(ctx, owner, "UTC"); out["started"] != false || len(spaces.asks) != 1 {
		t.Fatal("the first day runs once")
	}
	if !strings.Contains(spaces.asks[0], "<replies>Sounds right | Something's off</replies>") {
		t.Fatal("the greeting ends with the two replies")
	}
}

func TestResearchIsProactiveAndPostsSuggestions(t *testing.T) {
	s, spaces, _, ctx := harness(t)
	owner, _ := identity.Parse(ownerHex)
	spaces.onResearch = func(ctx context.Context) {
		if vmm.InitiatorFrom(ctx).Kind != vmm.InitiatorProactive {
			t.Error("research runs as initiator proactive")
		}
		_, _ = s.AgentTool(ctx, gate.ToolCall{Tool: "offer_task", Args: `{"title":"Renew the display permit","reason":"expires on the 30th"}`, ActorID: ownerHex, SpaceID: homeHex})
	}
	result, err := s.Research(ctx, owner)
	if err != nil || result != "1 suggestions" {
		t.Fatalf("%q %v", result, err)
	}
	if len(spaces.posts) != 2 || !strings.Contains(spaces.posts[1], `"c":"Suggestion"`) {
		t.Fatalf("the lead writes first, with the suggestion as a card: %v", spaces.posts)
	}
}
