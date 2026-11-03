package harness

import (
	"context"
	"encoding/json"
	"hash/fnv"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// wordVector embeds text as a bag of hashed words: texts sharing words point
// the same way, so recall by meaning is testable without a model.
func wordVector(text string) []float32 {
	v := make([]float32, 64)
	for _, w := range strings.Fields(strings.ToLower(text)) {
		h := fnv.New32a()
		_, _ = h.Write([]byte(strings.Trim(w, ".,!?")))
		v[h.Sum32()%64]++
	}
	return v
}

type memoryCharge struct {
	space, payer, payee identity.ID
	amount              int64
}

// memoryModels serves the embedding and chat models; learned is what the chat
// model "extracts" from a turn.
func testMemoryModels(t *testing.T, learned string) (*vmm.ProviderConfig, *vmm.ProviderConfig) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		w.Header().Set("Content-Type", "application/json")
		if strings.HasSuffix(r.URL.Path, "/embeddings") {
			input := body["input"].([]any)[0].(string)
			_ = json.NewEncoder(w).Encode(map[string]any{"data": []any{map[string]any{"embedding": wordVector(input)}},
				"usage": map[string]any{"prompt_tokens": 400000}})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": learned}}},
			"usage": map[string]any{"prompt_tokens": 1000, "completion_tokens": 100}})
	}))
	t.Cleanup(srv.Close)
	owner := identity.MustParse("0000000000000001000000000000000f")
	chat := vmm.ProviderConfig{BaseURL: srv.URL + "/v1", Model: "chat", InputPrice: 1, OutputPrice: 1, OwnerID: owner.String()}
	embed := vmm.ProviderConfig{BaseURL: srv.URL + "/v1", Model: "embed", InputPrice: 5, OwnerID: owner.String()}
	return &chat, &embed
}

func memoryAdapter(t *testing.T, chat, embed *vmm.ProviderConfig) (*Adapter, *[]memoryCharge) {
	t.Helper()
	a, _, _ := newTestAdapter(t)
	a.platform = fakePlatform{memoryChat: chat, memoryEmbedding: embed}
	a.mem = newMemoryStore(nil, a.platform, a.memory, logger.New(io.Discard, slog.LevelError))
	a.mem.db = memory.New(logger.New(io.Discard, slog.LevelError))
	charges := []memoryCharge{}
	a.memoryRecordFn = func(identity.ID, int64, int64, int64) {}
	a.memoryChargeFn = func(_ context.Context, space, payer, payee identity.ID, amount int64, _ string) error {
		charges = append(charges, memoryCharge{space, payer, payee, amount})
		return nil
	}
	return a, &charges
}

// roomSession registers a turn session of one agent in one space.
func roomSession(a *Adapter, token, space, bot string, noMemory bool) *session {
	base := vmm.WithExecution(context.Background(), vmm.Execution{SpaceID: space, ActorID: "00000000000000010000000000000a11", NoMemory: noMemory})
	s := &session{token: token, spaceID: space, botID: bot, account: identity.MustParse("00000000000000010000000000000b07"), base: base}
	a.mu.Lock()
	a.sessions[token] = s
	a.mu.Unlock()
	return s
}

func personSession(a *Adapter, token string, person identity.ID) *session {
	s := &session{token: token, personal: true, account: person, base: context.Background()}
	a.mu.Lock()
	a.sessions[token] = s
	a.mu.Unlock()
	return s
}

func post(t *testing.T, serve network.Handler, token, body string) map[string]any {
	t.Helper()
	resp, err := serve(context.Background(), &network.Request{Header: map[string]string{"Authorization": "Bearer " + token}, Body: []byte(body)})
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]any{"_status": float64(resp.Status)}
	_ = json.Unmarshal(resp.Body, &out)
	return out
}

func recallTexts(t *testing.T, a *Adapter, token, query string) []string {
	t.Helper()
	out := post(t, a.serveRecall, token, `{"query":`+jsonString(query)+`}`)
	var texts []string
	items, _ := out["items"].([]any)
	for _, it := range items {
		texts = append(texts, it.(map[string]any)["text"].(string))
	}
	return texts
}

func jsonString(s string) string { b, _ := json.Marshal(s); return string(b) }

const (
	spaceOne = "0000000000000001000000000000a001"
	spaceTwo = "0000000000000001000000000000b001"
)

func TestMemoriesAreRecalledByMeaningWithinTheirScope(t *testing.T) {
	chat, embed := testMemoryModels(t, `{"memories":[]}`)
	a, _ := memoryAdapter(t, chat, embed)
	roomSession(a, "coder", spaceOne, "bot-coder", false)
	roomSession(a, "writer", spaceOne, "bot-writer", false)
	roomSession(a, "other", spaceTwo, "bot-coder", false)

	for _, body := range []string{
		`{"text":"Sara prefers the blue theme for dashboards","kind":"preference","shared":true}`,
		`{"text":"deploys run from the release branch","kind":"procedure"}`,
	} {
		if out := post(t, a.serveRemember, "coder", body); out["ok"] != true {
			t.Fatalf("remember = %v", out)
		}
	}
	if got := recallTexts(t, a, "coder", "which theme does Sara prefer"); len(got) == 0 || got[0] != "Sara prefers the blue theme for dashboards" {
		t.Fatalf("coder recalls %v", got)
	}
	// Another agent of the space sees the shared memory, not the coder's own.
	got := recallTexts(t, a, "writer", "release branch deploys")
	for _, m := range got {
		if strings.Contains(m, "release branch") {
			t.Fatalf("writer recalls the coder's own memory: %v", got)
		}
	}
	if got := recallTexts(t, a, "writer", "Sara theme"); len(got) != 1 {
		t.Fatalf("writer recalls %v", got)
	}
	// Another space sees nothing of this one, even as the same agent.
	if got := recallTexts(t, a, "other", "Sara theme release branch"); len(got) != 0 {
		t.Fatalf("another space recalls %v", got)
	}
	// The same memory twice is kept once.
	post(t, a.serveRemember, "coder", `{"text":"Sara prefers the blue theme for dashboards","shared":true}`)
	if got := recallTexts(t, a, "writer", "Sara theme"); len(got) != 1 {
		t.Fatalf("a repeated memory was kept twice: %v", got)
	}
}

func TestWithoutAnEmbeddingModelMemoriesAreRecalledByWords(t *testing.T) {
	a, _ := memoryAdapter(t, nil, nil)
	roomSession(a, "coder", spaceOne, "bot-coder", false)
	post(t, a.serveRemember, "coder", `{"text":"the staging database lives on db-2"}`)
	if got := recallTexts(t, a, "coder", "where is the staging database"); len(got) != 1 {
		t.Fatalf("recall by words = %v", got)
	}
	if got := recallTexts(t, a, "coder", "unrelated question"); len(got) != 0 {
		t.Fatalf("unrelated recall = %v", got)
	}
}

func TestNotesAreScopedAndCorrectableFromTheMemoryScreen(t *testing.T) {
	a, _ := memoryAdapter(t, nil, nil)
	roomSession(a, "coder", spaceOne, "bot-coder", false)
	roomSession(a, "writer", spaceOne, "bot-writer", false)
	post(t, a.serveNotesSet, "coder", `{"content":"Ship on Fridays.","shared":true}`)
	post(t, a.serveNotesSet, "coder", `{"content":"I own the build."}`)
	get := func(token string) map[string]any {
		resp, _ := a.serveNotesGet(context.Background(), &network.Request{Header: map[string]string{"Authorization": "Bearer " + token}})
		out := map[string]any{}
		_ = json.Unmarshal(resp.Body, &out)
		return out
	}
	if n := get("coder"); n["space"] != "Ship on Fridays." || n["own"] != "I own the build." {
		t.Fatalf("coder notes = %v", n)
	}
	if n := get("writer"); n["space"] != "Ship on Fridays." || n["own"] != "" {
		t.Fatalf("writer notes = %v", n)
	}
	// People read and correct the same notes on the project's Memory screen.
	if err := a.EngineMemoryWrite(context.Background(), "", spaceOne, "bot-coder", "I own the build and the deploys."); err != nil {
		t.Fatal(err)
	}
	view, err := a.EngineMemoryRead(context.Background(), "", spaceOne, "bot-coder")
	if err != nil || view.SpaceNotes != "Ship on Fridays." || view.Notes != "I own the build and the deploys." {
		t.Fatalf("memory screen = %+v, %v", view, err)
	}
	if n := get("coder"); n["own"] != "I own the build and the deploys." {
		t.Fatalf("the agent does not read the corrected notes: %v", n)
	}
}

func TestAPersonsMemoryIsTheirsAlone(t *testing.T) {
	chat, embed := testMemoryModels(t, `{"memories":[]}`)
	a, charges := memoryAdapter(t, chat, embed)
	ann := identity.MustParse("00000000000000010000000000000a11")
	bob := identity.MustParse("00000000000000010000000000000b0b")
	personSession(a, "ann", ann)
	personSession(a, "bob", bob)
	roomSession(a, "coder", spaceOne, "bot-coder", false)
	post(t, a.serveRemember, "ann", `{"text":"Ann's sister is called Mina"}`)
	if got := recallTexts(t, a, "ann", "what is Ann's sister called"); len(got) != 1 {
		t.Fatalf("ann recalls %v", got)
	}
	if got := recallTexts(t, a, "bob", "sister name Mina"); len(got) != 0 {
		t.Fatalf("bob recalls ann's memory: %v", got)
	}
	if got := recallTexts(t, a, "coder", "sister name Mina"); len(got) != 0 {
		t.Fatalf("a space agent recalls ann's memory: %v", got)
	}
	// Shared means nothing without a space: it stays the person's.
	if out := post(t, a.serveNotesSet, "ann", `{"content":"x","shared":true}`); out["_status"] == float64(200) {
		t.Fatal("a person's assistant wrote shared notes")
	}
	// The person pays for their own memory, with no project.
	a.billMemory(context.Background())
	found := false
	for _, c := range *charges {
		if c.payer == ann && c.space.IsZero() {
			found = true
		}
	}
	if !found {
		t.Fatalf("personal memory was not charged: %+v", *charges)
	}
}

func TestATurnTeachesTheMemory(t *testing.T) {
	chat, embed := testMemoryModels(t, "```json\n{\"memories\":[{\"text\":\"The client is called Orbit\",\"kind\":\"fact\",\"shared\":true},{\"text\":\"\"}]}\n```")
	a, _ := memoryAdapter(t, chat, embed)
	s := roomSession(a, "coder", spaceOne, "bot-coder", false)
	scope, _ := s.memoryScope()
	n, err := a.mem.learn(context.Background(), scope, transcript{Message: "make a deck for Orbit", Reply: "done", Tools: []string{"write_file"}})
	if err != nil || n != 1 {
		t.Fatalf("learned %d, %v", n, err)
	}
	roomSession(a, "writer", spaceOne, "bot-writer", false)
	if got := recallTexts(t, a, "writer", "what is the client called"); len(got) != 1 || got[0] != "The client is called Orbit" {
		t.Fatalf("the team does not recall the learned memory: %v", got)
	}
	// A request processed without memory teaches nothing and reads nothing.
	fresh := roomSession(a, "fresh", spaceOne, "bot-coder", true)
	a.learnLater(fresh, &transcript{Message: "x", Reply: "y"})
	if out := post(t, a.serveRecall, "fresh", `{"query":"client"}`); out["_status"] != float64(403) {
		t.Fatalf("no-memory recall = %v", out)
	}
}

func TestAProjectPaysForItsMemoryAndStopsWhenItCannot(t *testing.T) {
	chat, embed := testMemoryModels(t, `{"memories":[]}`)
	a, charges := memoryAdapter(t, chat, embed)
	roomSession(a, "coder", spaceOne, "bot-coder", false)
	post(t, a.serveRemember, "coder", `{"text":"one fact worth keeping"}`)
	a.billMemory(context.Background())
	space := identity.MustParse(spaceOne)
	if len(*charges) != 1 || (*charges)[0].space != space || (*charges)[0].amount != 2 {
		t.Fatalf("charges = %+v", *charges)
	}
	// The project cannot pay: no memory model calls until it can.
	a.memoryChargeFn = func(context.Context, identity.ID, identity.ID, identity.ID, int64, string) error {
		return errs.New(errs.CodeFinance, "insufficient funds")
	}
	post(t, a.serveRemember, "coder", `{"text":"another fact"}`)
	a.billMemory(context.Background())
	if !a.memory.isBlocked(space) {
		t.Fatal("a project that cannot pay is not blocked")
	}
	if _, err := a.mem.embed(context.Background(), memoryScope{payer: space}, "x"); errs.CodeOf(err) != errs.CodeFinance {
		t.Fatalf("embedding while blocked = %v", err)
	}
}
