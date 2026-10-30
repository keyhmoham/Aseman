package deepagents

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func TestTheTimelineIsServedForTheTurnsSpaceOnly(t *testing.T) {
	a, _, _ := newTestAdapter(t)
	var asked []string
	a.platform = fakePlatform{timeline: func(space string, body []byte) ([]byte, error) {
		asked = append(asked, space)
		return []byte(`{"jsonrpc":"2.0","id":1,"result":{}}`), nil
	}}
	a.sessions["tok"] = &session{token: "tok", spaceID: "space-a", base: context.Background()}
	a.sessions["fresh"] = &session{token: "fresh", spaceID: "space-a",
		base: vmm.WithExecution(context.Background(), vmm.Execution{NoMemory: true})}
	serve := func(token, body string) *network.Response {
		resp, err := a.serveTimeline(context.Background(), &network.Request{
			Header: map[string]string{"Authorization": "Bearer " + token}, Body: []byte(body)})
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}
	// The body cannot name another space: the turn's space is used.
	if resp := serve("tok", `{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"space":"space-b"}}`); resp.Status != http.StatusOK {
		t.Fatalf("got %d %s", resp.Status, resp.Body)
	}
	if len(asked) != 1 || asked[0] != "space-a" {
		t.Fatalf("forwarded for %v", asked)
	}
	if resp := serve("nope", `{}`); resp.Status != http.StatusUnauthorized {
		t.Fatalf("unknown token: %d", resp.Status)
	}
	if resp := serve("fresh", `{"method":"tools/list"}`); resp.Status != http.StatusForbidden {
		t.Fatalf("a request without memory read the timeline: %d %s", resp.Status, resp.Body)
	}
	a.platform = fakePlatform{}
	if resp := serve("tok", `{"method":"tools/list"}`); resp.Status != http.StatusServiceUnavailable || !strings.Contains(string(resp.Body), "not configured") {
		t.Fatalf("timeline off: %d %s", resp.Status, resp.Body)
	}
}

func TestATurnSaysWhetherItHasATimeline(t *testing.T) {
	for _, on := range []bool{true, false} {
		a, rt, _ := newTestAdapter(t)
		p := fakePlatform{provider: vmm.ProviderConfig{Model: "m1"}}
		if on {
			p.timeline = func(string, []byte) ([]byte, error) { return nil, nil }
		}
		a.platform = p
		turn := testTurn()
		turn.Agent.AccountID = mustID(t)
		if _, err := a.Prompt(context.Background(), onlyVM(t, a), turn); err != nil {
			t.Fatal(err)
		}
		if got := rt.turns[0].Timeline; got != on {
			t.Fatalf("timeline sent to the runtime = %v, want %v", got, on)
		}
	}
}

func TestATurnSaysWhetherOpenCodeBuildsApps(t *testing.T) {
	for _, on := range []bool{true, false} {
		a, rt, _ := newTestAdapter(t)
		a.platform = fakePlatform{provider: vmm.ProviderConfig{Model: "m1"}, openCode: on}
		turn := testTurn()
		turn.Agent.AccountID = mustID(t)
		if _, err := a.Prompt(context.Background(), onlyVM(t, a), turn); err != nil {
			t.Fatal(err)
		}
		if got := rt.turns[0].OpenCode; got != on {
			t.Fatalf("opencode sent to the runtime = %v, want %v", got, on)
		}
		if rt.turns[0].AgentEngine != "deepagents" {
			t.Fatalf("programmer switch must not select the agentic engine: %q", rt.turns[0].AgentEngine)
		}
	}
}

func TestATurnUsesTheAgenticEngineTheAdminJustSet(t *testing.T) {
	for _, engine := range []string{"deepagents", "opencode"} {
		a, rt, _ := newTestAdapter(t)
		a.platform = fakePlatform{provider: vmm.ProviderConfig{Model: "m1"}, agentEngine: engine, openCode: engine == "deepagents"}
		turn := testTurn()
		turn.Agent.AccountID = mustID(t)
		if _, err := a.Prompt(context.Background(), onlyVM(t, a), turn); err != nil {
			t.Fatal(err)
		}
		if got := rt.turns[0].AgentEngine; got != engine {
			t.Fatalf("agent_engine sent to the runtime = %q, want %q", got, engine)
		}
		// The programmer switch stays whatever it was; the engine does not flip it.
		if engine == "opencode" && rt.turns[0].OpenCode {
			t.Fatal("opencode engine must not force the programmer switch on")
		}
	}
}
