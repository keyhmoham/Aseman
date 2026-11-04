package harness

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// fakeRouter records dispatched actions and answers with a fixed body.
type fakeRouter struct {
	api.ActionRouter
	mu    sync.Mutex
	calls []dispatched
}

type dispatched struct {
	ns, name string
	caller   api.Caller
	body     string
	scoped   string // the run id carried by the dispatch context
}

func (r *fakeRouter) Dispatch(ctx context.Context, ns, name string, req *api.ActionRequest) (*api.ActionResponse, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, dispatched{ns: ns, name: name, caller: req.Caller, body: string(req.Body), scoped: vmm.ExecutionFrom(ctx).RunID})
	return &api.ActionResponse{Body: []byte(`{"ok":true}`)}, nil
}

type fakeKernel struct {
	api.Kernel
	router *fakeRouter
}

func (k fakeKernel) Actions() api.ActionRouter { return k.router }
func (k fakeKernel) VMMFor(vmm.Type) vmm.VMM   { return nil }
func (k fakeKernel) Env() map[string]string    { return nil }
func (k fakeKernel) NodeID() identity.NodeID   { return identity.NodeID(1) }
func (k fakeKernel) Logger() *logger.Logger    { return nil }

// Resolve finds no other namespace: governance is not loaded in these tests.
func (k fakeKernel) Resolve(string) (any, error) { return nil, errs.NotFound("not loaded") }

// fakeRuntime is the Python runtime's HTTP contract.
type fakeRuntime struct {
	mu        sync.Mutex
	turns     []turnRequest
	answers   []turnRequest
	questions []vmm.AgentQuestion
	reply     turnResult
	adapter   *Adapter
	// gatewayLive records whether the turn token worked while the turn ran.
	gatewayLive bool
	// chats are the personal chats asked of the runtime; onChat runs while one
	// is answered (the engine's model calls on its gateway session).
	chats  []map[string]any
	onChat func(body map[string]any)
	// memory is the engine memory the runtime serves; memoryWrites what was saved.
	memory       map[string]any
	memoryWrites []map[string]any
	memoryQuery  string
}

func (f *fakeRuntime) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("X-Aseman-Runtime") != "secret" {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"bad runtime secret"}`))
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	switch r.URL.Path {
	case "/healthz":
		_, _ = w.Write([]byte(`{"ok":true}`))
	case "/v1/questions":
		_ = json.NewEncoder(w).Encode(map[string]any{"questions": f.questions})
	case "/v1/chat":
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.chats = append(f.chats, body)
		if f.onChat != nil {
			f.onChat(body)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"reply": "hello from the engine", "status": "done"})
	case "/v1/engines/deepseek/memory":
		if r.Method == http.MethodPost {
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			f.memoryWrites = append(f.memoryWrites, body)
			_, _ = w.Write([]byte(`{"saved":true}`))
			return
		}
		f.memoryQuery = r.URL.RawQuery
		_ = json.NewEncoder(w).Encode(f.memory)
	case "/v1/turns", "/v1/answers":
		var req turnRequest
		_ = json.NewDecoder(r.Body).Decode(&req)
		if r.URL.Path == "/v1/turns" {
			f.turns = append(f.turns, req)
		} else {
			f.answers = append(f.answers, req)
		}
		f.gatewayLive = f.adapter.byToken(req.Token) != nil
		_ = json.NewEncoder(w).Encode(f.reply)
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func newTestAdapter(t *testing.T) (*Adapter, *fakeRuntime, *fakeRouter) {
	t.Helper()
	a := New(logger.New(io.Discard, slog.LevelError))
	router := &fakeRouter{}
	a.k = fakeKernel{router: router}
	rt := &fakeRuntime{adapter: a, reply: turnResult{Reply: "done it", Status: "done"}}
	srv := httptest.NewServer(rt)
	t.Cleanup(srv.Close)
	a.runtimeURL, a.secret, a.nodeURL = srv.URL, "secret", "http://node:8080"
	if _, err := a.CreateVM(context.Background(), vmm.VMSpec{Type: vmm.TypeHarness, Name: "coder", YML: "name: coder\nmodel: m1\nrole: specialist\n"}); err != nil {
		t.Fatal(err)
	}
	return a, rt, router
}

func onlyVM(t *testing.T, a *Adapter) string {
	t.Helper()
	vms, _ := a.ListVMs(context.Background(), vmm.Filter{})
	if len(vms) != 1 {
		t.Fatalf("want one agent, got %d", len(vms))
	}
	return vms[0].ID
}

func testTurn() vmm.AgentTurn {
	return vmm.AgentTurn{
		Agent:   vmm.AgentIdentity{BotID: "bot-1", AccountID: identity.ID{}.String()},
		SpaceID: "space-1", RoomID: "room-1", MessageID: "msg-1", SenderName: "ann", Message: "build it",
	}
}

func TestPromptRunsATurnWithAScopedToken(t *testing.T) {
	a, rt, _ := newTestAdapter(t)
	vmID := onlyVM(t, a)
	turn := testTurn()
	turn.Agent.AccountID = mustID(t)
	reply, err := a.Prompt(context.Background(), vmID, turn)
	if err != nil || reply != "done it" {
		t.Fatalf("Prompt = %q, %v", reply, err)
	}
	req := rt.turns[0]
	if req.Gateway != "http://node:8080"+gatewayPrefix || req.Token == "" || !rt.gatewayLive {
		t.Fatalf("turn request %+v (token live during turn: %v)", req, rt.gatewayLive)
	}
	if req.Agent.Name != "coder" || req.Agent.Model != "m1" || req.Agent.VMID != vmID || req.Turn.MessageID != "msg-1" {
		t.Fatalf("agent payload %+v", req.Agent)
	}
	if a.byToken(req.Token) != nil {
		t.Fatal("the turn token outlived its turn")
	}
}

func TestPromptReportsRuntimeFailure(t *testing.T) {
	a, rt, _ := newTestAdapter(t)
	rt.reply = turnResult{Status: "failed", Error: "model unreachable"}
	turn := testTurn()
	turn.Agent.AccountID = mustID(t)
	if _, err := a.Prompt(context.Background(), onlyVM(t, a), turn); err == nil || !strings.Contains(err.Error(), "model unreachable") {
		t.Fatalf("want the runtime's failure, got %v", err)
	}
}

func TestReplyOnlyAnswersAnOpenQuestion(t *testing.T) {
	a, rt, _ := newTestAdapter(t)
	vmID := onlyVM(t, a)
	turn := testTurn()
	turn.Agent.AccountID = mustID(t)
	ok, _, err := a.Reply(context.Background(), vmID, turn)
	if ok || err != nil || len(rt.answers) != 0 {
		t.Fatalf("no open question: Reply = %v, %v (answers sent %d)", ok, err, len(rt.answers))
	}
	rt.questions = []vmm.AgentQuestion{{ID: "q1", RoomID: "room-1", Question: "Which color?"}}
	rt.reply = turnResult{Answered: true, Reply: "Using blue", Status: "done"}
	ok, reply, err := a.Reply(context.Background(), vmID, turn)
	if !ok || reply != "Using blue" || err != nil || len(rt.answers) != 1 {
		t.Fatalf("Reply = %v %q %v", ok, reply, err)
	}
	qs, err := a.Questions(context.Background(), vmID, "space-1")
	if err != nil || len(qs) != 1 || qs[0].Agent != "coder" {
		t.Fatalf("Questions = %+v, %v", qs, err)
	}
}

func TestGatewayDispatchesAllowedActionsInTheTurnScope(t *testing.T) {
	a, _, router := newTestAdapter(t)
	account := identity.ID{}
	s := &session{token: "tok", def: a.agents[onlyVM(t, a)], account: account, spaceID: "space-1", roomID: "room-1",
		base: vmm.WithExecution(context.Background(), vmm.Execution{RunID: "run-7"})}
	a.sessions["tok"] = s
	call := func(token, body string) *network.Response {
		resp, err := a.serveCall(context.Background(), &network.Request{Header: map[string]string{"Authorization": "Bearer " + token}, Body: []byte(body)})
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}
	if r := call("nope", `{"namespace":"spaces","action":"message_send"}`); r.Status != http.StatusUnauthorized {
		t.Fatalf("bad token: %d", r.Status)
	}
	if r := call("tok", `{"namespace":"admin","action":"users_list"}`); r.Status != http.StatusForbidden {
		t.Fatalf("disallowed action: %d", r.Status)
	}
	if r := call("tok", `{"namespace":"spaces","action":"message_send","body":{"space":"other"}}`); r.Status != http.StatusForbidden {
		t.Fatalf("other space: %d", r.Status)
	}
	// Rooms and threads are checked too, whatever the field is called.
	a.platform = fakePlatform{rooms: map[string]string{"room-1": "space-1", "room-9": "other"}}
	for _, body := range []string{`{"space_id":"other"}`, `{"room":"room-9"}`, `{"space":"space-1","thread":"room-9"}`, `{"room_id":"unknown"}`} {
		if r := call("tok", `{"namespace":"spaces","action":"message_send","body":`+body+`}`); r.Status != http.StatusForbidden {
			t.Fatalf("%s: %d", body, r.Status)
		}
	}
	if r := call("tok", `{"namespace":"spaces","action":"message_send","body":{"space":"space-1","room":"room-1","body":"hi"}}`); r.Status != http.StatusOK {
		t.Fatalf("allowed action: %d %s", r.Status, r.Body)
	}
	got := router.calls[len(router.calls)-1]
	if got.ns != "spaces" || got.name != "message_send" || got.caller.Kind != "bot" || got.scoped != "run-7" {
		t.Fatalf("dispatched %+v", got)
	}
}

func TestParseUsage(t *testing.T) {
	in, out := parseUsage([]byte(`{"usage":{"prompt_tokens":12,"completion_tokens":5}}`), false)
	if in != 12 || out != 5 {
		t.Fatalf("plain usage %d/%d", in, out)
	}
	stream := "data: {\"choices\":[]}\n\ndata: {\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3}}\n\ndata: [DONE]\n"
	in, out = parseUsage([]byte(stream), true)
	if in != 7 || out != 3 {
		t.Fatalf("stream usage %d/%d", in, out)
	}
}

func mustID(t *testing.T) string {
	t.Helper()
	id, err := identity.New(identity.NodeID(1))
	if err != nil {
		t.Fatal(err)
	}
	return id.String()
}

// A turn's session counts its time from when the turn opened: the gate that
// stops a run at the budget prices what the run has used so far, so a zero
// start time would price every turn as centuries of work.
func TestOpenedSessionsKnowWhenTheirTurnStarted(t *testing.T) {
	a, _, _ := newTestAdapter(t)
	turn := testTurn()
	turn.Agent.AccountID = mustID(t)
	s, _, err := a.open(context.Background(), onlyVM(t, a), turn)
	if err != nil {
		t.Fatal(err)
	}
	defer a.close(s)
	if age := time.Since(s.started); s.started.IsZero() || age < 0 || age > time.Minute {
		t.Fatalf("session started = %v (age %v)", s.started, age)
	}
}

// Before each model call the gate asks the node whether the turn can still pay,
// with the turn's payer and bot and what it has used so far; a refusal stops
// the call with a 402 before the provider is reached, and the turn's metered
// tokens are what the next check prices.
func TestGateStopsAModelCallTheTurnCannotPayFor(t *testing.T) {
	a, _, _ := newTestAdapter(t)
	payer, bot := identity.ID{}, identity.ID{}
	payer, _ = identity.New(1)
	bot, _ = identity.New(1)
	base := vmm.WithExecution(context.Background(), vmm.Execution{ActorID: payer.String(), SpaceID: "space-1"})
	s := &session{token: "tok", def: a.agents[onlyVM(t, a)], botID: bot.String(), base: base, started: time.Now().Add(-5 * time.Second)}
	a.sessions["tok"] = s

	var got struct {
		payer, bot             identity.ID
		seconds, tokIn, tokOut int64
		calls                  int
	}
	var refuse error
	a.gateFn = func(_ context.Context, p, b identity.ID, secs, in, out int64) error {
		got.payer, got.bot, got.seconds, got.tokIn, got.tokOut = p, b, secs, in, out
		got.calls++
		return refuse
	}
	a.meter(s, 120, 30)
	if err := a.gate(s); err != nil {
		t.Fatal(err)
	}
	if got.payer != payer || got.bot != bot || got.seconds < 5 || got.tokIn != 120 || got.tokOut != 30 {
		t.Fatalf("gate asked about %+v; want the payer, the bot, >=5s and 120/30 tokens", got)
	}
	refuse = errs.New(errs.CodeFinance, "project budget exceeded")
	resp, err := a.serveChat(context.Background(), &network.Request{Header: map[string]string{"Authorization": "Bearer tok"}, Body: []byte(`{"messages":[]}`)})
	if err != nil || resp.Status != http.StatusPaymentRequired || !strings.Contains(string(resp.Body), "project budget exceeded") {
		t.Fatalf("serveChat past the budget = %v %s %v; want 402 naming the budget", resp.Status, resp.Body, err)
	}
	// No payer (not a metered run): no gate.
	got.calls = 0
	if err := a.gate(&session{base: context.Background(), started: time.Now()}); err != nil || got.calls != 0 {
		t.Fatalf("an unmetered session was gated: %v (%d calls)", err, got.calls)
	}
}

// The gate reads a spaces.ask as what it does and returns that part's
// arguments (secrets put in); the ask keeps its space, room and the rest.
func TestAGovernedAskKeepsItsShape(t *testing.T) {
	tool := askBody([]byte(`{"space":"s","room":"r","tool":"appui_create","args":{"brief":"earth"}}`),
		gate.Result{Args: json.RawMessage(`{"brief":"earth with key k"}`)})
	var got map[string]any
	_ = json.Unmarshal(tool, &got)
	if got["space"] != "s" || got["room"] != "r" || got["tool"] != "appui_create" || got["args"].(map[string]any)["brief"] != "earth with key k" {
		t.Fatalf("tool ask = %s", tool)
	}
	cmd := askBody([]byte(`{"space":"s","bot":"sandbox","body":"echo {{secret:k}}","raw":true}`),
		gate.Result{Args: json.RawMessage(`{"space":"s","bot":"sandbox","body":"echo {{secret:k}}","raw":true}`), Command: "echo 'v'"})
	_ = json.Unmarshal(cmd, &got)
	if got["space"] != "s" || got["body"] != "echo 'v'" || got["raw"] != true {
		t.Fatalf("command ask = %s", cmd)
	}
	fn := askBody([]byte(`{"space":"s","bot":"b","body":"{\"function\":\"f\",\"payload\":{\"q\":\"{{secret:k}}\"}}"}`),
		gate.Result{Args: json.RawMessage(`{"q":"v"}`)})
	_ = json.Unmarshal(fn, &got)
	var call map[string]any
	_ = json.Unmarshal([]byte(got["body"].(string)), &call)
	if got["space"] != "s" || call["function"] != "f" || call["payload"].(map[string]any)["q"] != "v" {
		t.Fatalf("function ask = %s", fn)
	}
	plain := askBody([]byte(`{"space":"s","bot":"b","body":"hi"}`), gate.Result{Args: json.RawMessage(`{"space":"s","bot":"b","body":"hi"}`)})
	_ = json.Unmarshal(plain, &got)
	if got["space"] != "s" || got["body"] != "hi" {
		t.Fatalf("plain ask = %s", plain)
	}
}
