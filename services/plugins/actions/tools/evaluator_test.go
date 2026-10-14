package tools

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/kernel"
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/actions/tools/mechanisms/mcp"
	"github.com/tradera/tradera/plugins/actions/tools/models"
	"github.com/tradera/tradera/plugins/adapters/database/memory"
	"github.com/tradera/tradera/plugins/testutil"
)

// settingsStub is the settings namespace as far as the evaluator needs it.
type settingsStub struct{ admins string }

func (s *settingsStub) AdminsSpace(context.Context) (string, error) { return s.admins, nil }

type stubProvider struct{ service any }

func (p stubProvider) Acquire(context.Context) (any, func(), error) { return p.service, func() {}, nil }

// evaluatorKernel is a node with a signing key and a settings namespace.
type evaluatorKernel struct {
	api.Kernel
	settings *settingsStub
}

func (k evaluatorKernel) Env() map[string]string {
	return map[string]string{"node_private_key": strings.Repeat("ab", 32)}
}

func (k evaluatorKernel) Resolve(name string) (any, error) {
	if name == "service/settings" {
		return stubProvider{k.settings}, nil
	}
	return k.Kernel.Resolve(name)
}

func TestTradersLeaderboardAsksTheAdminsSpaceEvaluator(t *testing.T) {
	ctx := context.Background()
	db := memory.New(logger.Global())
	for _, m := range append(testutil.Models(), models.Models()...) {
		if err := db.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	settings := &settingsStub{}
	k := evaluatorKernel{Kernel: kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global()}), settings: settings}
	s := &Service{K: k, R: &repo.Repo{DB: db}, Internal: mcp.New(true)}

	id := func(v string) identity.ID { return identity.MustParse(v) }
	admins, other := id("00000000000000010000000000000010"), id("00000000000000010000000000000011")
	reader := id("00000000000000010000000000000001")

	// The evaluator's backend: answers the node's MCP calls.
	var calls []map[string]any
	var headers []http.Header
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var msg map[string]any
		_ = json.NewDecoder(r.Body).Decode(&msg)
		w.Header().Set("Content-Type", "application/json")
		switch msg["method"] {
		case "initialize":
			_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": msg["id"], "result": map[string]any{"protocolVersion": "2025-06-18"}})
		case "tools/call":
			params := msg["params"].(map[string]any)
			calls, headers = append(calls, params), append(headers, r.Header.Clone())
			value := map[string]any{"board": "overall", "traders": []any{map[string]any{"handle": "daniel", "scores": map[string]any{"overall_score": 82}}}}
			if params["name"] == "trader_get" {
				value = map[string]any{"handle": params["arguments"].(map[string]any)["handle"], "report": map[string]any{"overall_score": 82}}
			}
			text, _ := json.Marshal(value)
			_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": msg["id"], "result": map[string]any{
				"content": []any{map[string]any{"type": "text", "text": string(text)}}, "structuredContent": value, "isError": false}})
		default:
			w.WriteHeader(http.StatusAccepted)
		}
	}))
	defer backend.Close()

	addTool := func(botID, accountID, name, space string) {
		now := time.Now().UTC()
		rec := &bot.Bot{Entity: entity.Entity{ID: id(botID), CreatedAt: now, UpdatedAt: now}, AccountID: id(accountID),
			Name: name, Kind: bot.KindTool, VMType: bot.VMType(models.RuntimeDocker), Status: bot.StatusRunning}
		if err := s.R.CreateID(ctx, "bots", rec.ID, rec); err != nil {
			t.Fatal(err)
		}
		tool := &models.Tool{ID: botID, BotID: botID, Mode: models.ModeManaged, Runtime: models.RuntimeDocker,
			URL: "/mcp", Endpoint: backend.URL, RuntimeKey: "key-" + name, UpdatedAt: now}
		if err := s.R.CreateID(ctx, "tool_registry", rec.ID, tool); err != nil {
			t.Fatal(err)
		}
		mem := &membership.Membership{Entity: entity.Entity{ID: id("0000000000000001000000000000" + botID[29:] + "9"), CreatedAt: now, UpdatedAt: now},
			SpaceID: id(space), MemberID: id(accountID), Role: membership.RoleBot, JoinedAt: now}
		if err := s.R.CreateID(ctx, "memberships", mem.ID, mem); err != nil {
			t.Fatal(err)
		}
	}
	// An evaluator in another project and another tool in the admins space are not it.
	addTool("00000000000000010000000000000101", "00000000000000010000000000000201", "evaluator", other.String())
	addTool("00000000000000010000000000000102", "00000000000000010000000000000202", "weather", admins.String())

	user := api.Caller{ID: reader, Kind: "user"}
	ask := func(action string, body string) (*api.ActionResponse, error) {
		req := &api.ActionRequest{Caller: user, Body: json.RawMessage(body)}
		if action == "traders_leaderboard" {
			return s.tradersLeaderboard(ctx, req)
		}
		return s.traderProfile(ctx, req)
	}

	if _, err := ask("traders_leaderboard", `{}`); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("no admins space: err = %v; want not found", err)
	}
	settings.admins = admins.String()
	if _, err := ask("traders_leaderboard", `{}`); errs.CodeOf(err) != errs.CodeNotFound {
		t.Fatalf("no evaluator in the admins space: err = %v; want not found", err)
	}

	addTool("00000000000000010000000000000103", "00000000000000010000000000000203", "Evaluator", admins.String())
	resp, err := ask("traders_leaderboard", `{"board":"technical","limit":5}`)
	if err != nil {
		t.Fatal(err)
	}
	var board map[string]any
	_ = json.Unmarshal(resp.Body, &board)
	if traders, _ := board["traders"].([]any); len(traders) != 1 {
		t.Fatalf("leaderboard = %s", resp.Body)
	}
	last := calls[len(calls)-1]
	if last["name"] != "leaderboard" || last["arguments"].(map[string]any)["board"] != "technical" {
		t.Fatalf("asked %v", last)
	}
	h := headers[len(headers)-1]
	// The reader asks outside any space: the evaluator can only read its own store for them.
	if h.Get(HeaderActor) != reader.String() || h.Get(HeaderSpace) != "" || h.Get(HeaderScope) == "" || h.Get(HeaderToken) == "" {
		t.Fatalf("scope headers %v", h)
	}

	resp, err = ask("trader_profile", `{"handle":"daniel"}`)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(resp.Body), `"report"`) || calls[len(calls)-1]["name"] != "trader_get" {
		t.Fatalf("profile = %s, asked %v", resp.Body, calls[len(calls)-1])
	}
	if _, err := ask("trader_profile", `{}`); errs.CodeOf(err) != errs.CodeInvalidArgument {
		t.Fatalf("no handle: err = %v", err)
	}
	if _, err := s.tradersLeaderboard(ctx, &api.ActionRequest{Caller: api.Caller{ID: reader, Kind: "bot"}, Body: json.RawMessage(`{}`)}); err == nil {
		t.Fatal("a bot read the leaderboard as a person")
	}
}
