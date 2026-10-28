package tools

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/tools/mechanisms/mcp"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// mailApp is an MCP server with a read function and a send function, and
// no "ask": plain words have to be turned into one of its functions.
func mailApp(t *testing.T, withAsk bool, calls *[]string) *endpoint {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			ID     any    `json:"id"`
			Method string `json:"method"`
			Params struct {
				Name      string         `json:"name"`
				Arguments map[string]any `json:"arguments"`
			} `json:"params"`
		}
		_ = json.NewDecoder(r.Body).Decode(&in)
		var result any
		switch in.Method {
		case "initialize":
			result = map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{}}
		case "tools/list":
			tools := []map[string]any{
				{"name": "mail_search", "description": "Search mail", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{"query": map[string]any{"type": "string"}}}},
				{"name": "mail_send", "description": "Send mail", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{"to": map[string]any{"type": "string"}}}},
			}
			if withAsk {
				tools = append(tools, map[string]any{"name": "ask", "description": "Free text", "inputSchema": map[string]any{"type": "object"}})
			}
			result = map[string]any{"tools": tools}
		case "tools/call":
			raw, _ := json.Marshal(in.Params.Arguments)
			*calls = append(*calls, in.Params.Name+" "+string(raw))
			result = map[string]any{"content": []map[string]any{{"type": "text", "text": "done: " + in.Params.Name}}}
		default:
			w.WriteHeader(http.StatusAccepted)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": in.ID, "result": result})
	}))
	t.Cleanup(srv.Close)
	return &endpoint{URL: srv.URL, Headers: map[string]string{}, Client: mcp.New(true)}
}

func TestPlainWordsReachAnApp(t *testing.T) {
	s := &Service{K: kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global()})}
	rec := &bot.Bot{Name: "Mail", Kind: bot.KindTool}
	rec.ID, _ = identity.Parse("00000000000000010000000000000077")
	person, _ := identity.Parse("00000000000000010000000000000001")
	var picked string
	s.Words = func(_ context.Context, c wordsCompletion) (string, error) {
		if !strings.Contains(c.User, "mail_send") || c.Payer != person {
			t.Errorf("the model sees the functions and bills the person: %+v", c)
		}
		return picked, nil
	}
	var calls []string
	ep := mailApp(t, false, &calls)
	ctx := context.Background()

	picked = `{"function":"mail_search","arguments":{"query":"invoice"}}`
	out, err := s.answerInWords(ctx, ep, rec, person, "", "any invoices this week?")
	if err != nil || out != "done: mail_search" || len(calls) != 1 || !strings.Contains(calls[0], "invoice") {
		t.Fatalf("words become one call: %q %v %v", out, err, calls)
	}
	picked = `{"reply":"Who should it go to?"}`
	if out, _ = s.answerInWords(ctx, ep, rec, person, "", "send it"); out != "Who should it go to?" || len(calls) != 1 {
		t.Fatalf("missing details are asked for, nothing is called: %q", out)
	}
	picked = `{"function":"format_disk","arguments":{}}`
	if _, err := s.answerInWords(ctx, ep, rec, person, "", "wipe it"); err == nil {
		t.Fatal("only the app's own functions")
	}

	// Behind an agent, the call the words became is decided by the gate:
	// with governance required and absent, it is refused before it runs.
	t.Setenv("ASEMAN_GOVERNANCE_REQUIRED", "1")
	picked = `{"function":"mail_send","arguments":{"to":"marco@example.com"}}`
	agentCtx := vmm.WithExecution(ctx, vmm.Execution{ActorID: person.String(), AgentID: "00000000000000010000000000000005"})
	if _, err := s.answerInWords(agentCtx, ep, rec, person, "", "send Marco the invoice"); err == nil || len(calls) != 1 {
		t.Fatalf("an agent's words are gated: %v %v", err, calls)
	}
	// The person asking themselves acts for themselves.
	selfCtx := vmm.WithExecution(ctx, vmm.Execution{ActorID: person.String(), AgentID: rec.ID.String()})
	if _, err := s.answerInWords(selfCtx, ep, rec, person, "", "send Marco the invoice"); err != nil || len(calls) != 2 {
		t.Fatalf("%v %v", err, calls)
	}

	// An app with its own "ask" takes the words itself.
	var askCalls []string
	if out, err := s.answerInWords(ctx, mailApp(t, true, &askCalls), rec, person, "", "hello"); err != nil || out != "done: ask" || !strings.Contains(askCalls[0], "hello") {
		t.Fatalf("%q %v %v", out, err, askCalls)
	}
}

func TestOnlyTheNodesOwnAppsUseTheInternalClient(t *testing.T) {
	t.Setenv("ASEMAN_TOOL_NODE_URL", "http://node:8080")
	s := &Service{Client: mcp.New(false), Internal: mcp.New(true)}
	if s.mcpClient("http://node:8080/google/v1/mcp") != s.Internal {
		t.Fatal("the Google app is served by this node")
	}
	for _, u := range []string{"http://node:8080.evil.example/mcp", "http://10.0.0.5/mcp", "https://backend.composio.dev/v3/mcp/x/mcp"} {
		if s.mcpClient(u) != s.Client {
			t.Fatalf("%s goes through the client that refuses private addresses", u)
		}
	}
}
