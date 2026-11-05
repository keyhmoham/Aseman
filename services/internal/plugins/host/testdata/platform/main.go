// This runner proves, on a whole node, that a person's agent can give them a
// product on Aseman: an organization with its own sub-platform, a fullstack
// app built in a space and wired to that space's real agents and apps, the
// organization's developer API in the app's server, and the app published as
// the platform's frontend — and that the platform's people then use it.
//
// It boots the node with every namespace as a native plugin (as production
// does), on the memory database and the HTTP adapter. Three things stand in
// for the outside world:
//
//   - the agents' runtime: a fake DeepSeek Harness host that, for the Builder
//     agent's turn, makes exactly the tool calls a model would, through the
//     node's real agent gateway (/harness/v1/call with the turn's token), and
//     answers the Advisor agent's asks;
//   - the space's computer: a VMM that runs commands on this machine in
//     /workspace (the runner needs root and a throwaway machine), so the real
//     aseman-appui kit lays out, checks (wiring included) and starts the app;
//   - the space's app: a remote MCP server ("Pricing") in this process.
//
// Run after make plugins: ASEMAN_PLATFORM_E2E=1 go test ./internal/plugins/host -run PlatformE2E
package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/aseman/aseman/internal/app"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/base"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
	"github.com/aseman/aseman/plugins/config"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func check(ok bool, format string, args ...any) {
	if !ok {
		panic(fmt.Sprintf("FAILED: "+format, args...))
	}
}

func step(format string, args ...any) { fmt.Printf("✓ "+format+"\n", args...) }

func main() {
	root, err := os.Getwd()
	must(err)
	kit := filepath.Join(root, "..", "deploy", "sandbox-computer", "appui")
	scratch, err := os.MkdirTemp("", "aseman-platform-e2e-")
	must(err)
	defer os.RemoveAll(scratch)
	workspace := "/workspace/appui/e2e-" + filepath.Base(scratch)

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	must(err)
	addr := listener.Addr().String()
	must(listener.Close())
	node := "http://" + addr
	// The app's server (on "the computer", this machine) reaches the node here.
	must(os.Setenv("ASEMAN_SANDBOX_APP_API_URL", node+"/appapi/v1"))
	for _, name := range []string{"ASEMAN_LLM_BASE_URL", "ASEMAN_LLM_API_KEY", "ASEMAN_LLM_MODEL", "ASEMAN_IMAGE_MODEL"} {
		must(os.Unsetenv(name))
	}

	cfg := &dconfig.Config{Node: dconfig.NodeConfig{ID: "0000000000000001", Name: "e2e-admin", Central: true}, Plugins: dconfig.PluginsConfig{SourceRoot: root, Directory: filepath.Join(root, "bin/plugins"), Adapters: []dconfig.PluginSpec{{Name: "memory", Enabled: true}, {Name: "local-cache", Enabled: true}, {Name: "local", Enabled: true, Config: map[string]any{"base_path": filepath.Join(scratch, "files")}}}}}
	cfg.Defaults()
	must(os.Chdir(scratch))
	defer os.Chdir(root)
	application, err := app.New(cfg, map[string]string{"admin_password": "e2e-test-password"})
	must(err)
	defer application.Shutdown(context.Background())
	must(application.Bootstrap(context.Background()))
	k := application.K
	ctx, cancelRun := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancelRun()

	// The space's computer: this machine.
	computer := &localVMM{Base: base.Base{Name: "local-sandbox", Category: api.CategoryVMM, Version: "1.0.0", Provides: []string{"vmm"}},
		vms: map[string]vmm.VM{}, env: []string{"ASEMAN_APPUI_ROOT=" + kit}}
	must(k.Register(computer))
	must(k.Init(computer.Info().Name))
	must(k.Start(computer.Info().Name))
	must(os.Symlink(filepath.Join(kit, "aseman-appui"), "/usr/local/bin/aseman-appui"))
	defer os.Remove("/usr/local/bin/aseman-appui")
	defer os.RemoveAll(workspace)

	// The space's app: a pricing service over MCP.
	var quotes atomic.Int32
	pricing := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var rpc struct {
			ID     any            `json:"id"`
			Method string         `json:"method"`
			Params map[string]any `json:"params"`
		}
		_ = json.NewDecoder(r.Body).Decode(&rpc)
		w.Header().Set("Content-Type", "application/json")
		result := map[string]any{}
		switch rpc.Method {
		case "initialize":
			w.Header().Set("Mcp-Session-Id", "s1")
			result = map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{"tools": map[string]any{}}, "serverInfo": map[string]any{"name": "pricing", "version": "1"}}
		case "tools/list":
			result = map[string]any{"tools": []any{map[string]any{"name": "quote", "description": "The price of a product", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{"sku": map[string]any{"type": "string"}}, "required": []string{"sku"}}}}}
		case "tools/call":
			quotes.Add(1)
			args, _ := rpc.Params["arguments"].(map[string]any)
			result = map[string]any{"content": []any{map[string]any{"type": "text", "text": fmt.Sprintf("%v costs 42 credits", args["sku"])}}}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": rpc.ID, "result": result})
	}))
	defer pricing.Close()

	// The agents' runtime. Bot ids are known once the agents exist.
	var builderID, advisorID atomic.Value
	builderID.Store("")
	advisorID.Store("")
	var advisorAsks atomic.Int32
	turnLog := &strings.Builder{}
	var turnMu sync.Mutex
	runtime := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Aseman-Runtime") != "e2e-secret" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/healthz":
			_, _ = w.Write([]byte(`{"ok":true}`))
		case "/v1/questions":
			_, _ = w.Write([]byte(`{"questions":[]}`))
		case "/v1/turns":
			var turn struct {
				Token   string `json:"token"`
				Gateway string `json:"gateway"`
				Agent   struct {
					BotID string `json:"bot_id"`
				} `json:"agent"`
				Turn vmm.AgentTurn `json:"turn"`
			}
			must(json.NewDecoder(r.Body).Decode(&turn))
			reply := "ok"
			switch turn.Agent.BotID {
			case advisorID.Load():
				advisorAsks.Add(1)
				reply = "Advisor: take the blue one"
			case builderID.Load():
				reply = builderTurn(turn.Gateway, turn.Token, turn.Turn.SpaceID, turn.Turn.RoomID, workspace, turnLog, &turnMu)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"reply": reply, "status": "done", "answered": true})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer runtime.Close()

	_, err = k.LoadPlugin(ctx, filepath.Join(root, "bin/plugins/adapters/harness.so"), map[string]any{"options": map[string]string{"runtime_url": runtime.URL, "runtime_secret": "e2e-secret", "node_url": node}})
	must(err)
	_, err = k.LoadPlugin(ctx, filepath.Join(root, "bin/plugins/adapters/http.so"), map[string]any{"addr": addr})
	must(err)
	serveCtx, stopServing := context.WithCancel(ctx)
	defer stopServing()
	go func() { _ = application.Serve(serveCtx) }()
	waitHTTP(node + "/healthz")
	must(bridge.Invoke(ctx, k, "llm", "SeedStatic", []any{ctx, vmm.ProviderConfig{Kind: "openai", BaseURL: runtime.URL, APIKey: "test-key", Model: "mock-model"}}))

	// The person, with credits, and their workspace.
	r := repo.New(k)
	person := personOn(ctx, k, r, "founder", "")
	actor := helper.WithActor(ctx, person.ID)
	must(bridge.Invoke(ctx, k, "finance", "Mint", []any{ctx, person.ID, person.ID, int64(50_000_000), "e2e credits"}, &json.RawMessage{}))
	var studio space.Space
	must(bridge.Invoke(actor, k, "spaces", "CreateSpace", []any{actor, person.ID, "Studio", ""}, &studio))
	agent := func(name string) bot.Bot {
		var b bot.Bot
		must(bridge.Invoke(actor, k, "bots", "CreateBot", []any{actor, person.ID, map[string]any{"name": name, "kind": "agent", "vm_type": "harness", "instructions": "Work for the person", "model": "mock-model"}}, &b))
		must(bridge.Invoke(actor, k, "bots", "Lifecycle", []any{actor, b.ID, "start"}, &b))
		must(bridge.Invoke(actor, k, "spaces", "AddBot", []any{actor, person.ID, studio.ID, identity.ID{}, b.AccountID}))
		return b
	}
	builder, advisor := agent("Builder"), agent("Advisor")
	builderID.Store(builder.ID.String())
	advisorID.Store(advisor.ID.String())
	registered := dispatch(ctx, k, person.ID, "tools", "mcp_register", map[string]any{"name": "Pricing", "url": pricing.URL})
	var pricingBot bot.Bot
	raw, _ := json.Marshal(registered["bot"])
	must(json.Unmarshal(raw, &pricingBot))
	must(bridge.Invoke(actor, k, "spaces", "AddBot", []any{actor, person.ID, studio.ID, identity.ID{}, pricingBot.AccountID}))
	step("a person with a workspace: agents Builder and Advisor, the Pricing app (MCP)")

	// The person asks; the Builder agent does the whole job with its tools.
	var reply string
	must(bridge.Invoke(actor, k, "spaces", "AskBot", []any{actor, studio.ID, builder.ID,
		"Make me a store for my brand Acme that my customers sign up to: advice from our Advisor and prices from Pricing.",
		[]vmm.FileAttachment(nil), []vmm.ChatMessage(nil)}, &reply))
	fmt.Print(turnLog.String())
	check(strings.HasPrefix(reply, "LIVE "), "the builder's turn did not finish: %s", reply)
	url := strings.TrimPrefix(reply, "LIVE ")
	check(url == "/v1/platforms/acme/app/", "published at %q", url)
	step("the Builder's turn published the platform at %s", url)

	// What the person now owns, as the developer console shows it.
	var orgs []map[string]any
	must(bridge.Invoke(ctx, k, "developer", "Orgs", []any{ctx, person.ID}, &orgs))
	var team string
	for _, o := range orgs {
		if o["name"] == "Acme Labs" && o["role"] == "owner" {
			team, _ = o["id"].(string)
		}
	}
	check(team != "", "no Acme Labs organization owned by the person: %v", orgs)
	got := dispatch(ctx, k, person.ID, "developer", "platform_get", map[string]any{"org": team})
	pv, _ := got["platform"].(map[string]any)
	fv, _ := pv["frontend"].(map[string]any)
	check(pv["slug"] == "acme" && fv != nil && fv["url"] == url && fv["ui"] == "web", "platform: %v", pv)
	wiring, _ := json.Marshal(fv["wiring"])
	check(strings.Contains(string(wiring), `"Advisor"`) && strings.Contains(string(wiring), `"Pricing"`) && !strings.Contains(string(wiring), `"Builder"`),
		"wiring: %s", wiring)
	keys := dispatch(ctx, k, person.ID, "developer", "keys_list", map[string]any{"org": team})
	keyList, _ := keys["keys"].([]any)
	check(len(keyList) == 1, "one developer key for the app: %v", keys)
	env, err := os.ReadFile(workspace + "/.aseman/server.env")
	must(err)
	check(bytes.Contains(env, []byte("ASEMAN_DEVELOPER_KEY=dk_live_")) && bytes.Contains(env, []byte("ASEMAN_PLATFORM=acme")) &&
		bytes.Contains(env, []byte("ASEMAN_APP_KEY=aak_")), "server settings: %s", env)
	check(!strings.Contains(turnLog.String(), "dk_live_"), "the developer key reached the agent")
	step("organization Acme Labs, platform acme, frontend %q wired to Advisor + Pricing, one developer key in the server's settings only", fv["title"])

	// The platform's people.
	pid, _ := pv["id"].(string)
	customer := personOn(ctx, k, r, "shopper", pid)
	_ = customer
	jar, _ := cookiejar.New(nil)
	web := &http.Client{Timeout: 3 * time.Minute, Jar: jar}
	status, body := request(web, "GET", node+url, nil)
	check(status == 200 && strings.Contains(body, "Welcome to Acme") && strings.Contains(body, "Visitor"), "visitor page: %d %s", status, body)
	status, body = request(web, "GET", node+url+"api/advice?sku=B7", nil)
	check(status == 401, "a visitor got advice: %d %s", status, body)
	status, body = request(web, "GET", node+url+"_aseman/api/agents", nil)
	check(status == 401, "a visitor reached the space's agents: %d %s", status, body)
	step("a visitor sees the storefront and reaches no agent or app")

	status, body = request(web, "POST", node+url+"_aseman/auth/login", map[string]any{"account": "shopper", "password": "e2e-password-1"})
	check(status == 200 && !strings.Contains(body, "token"), "sign-in: %d %s", status, body)
	status, body = request(web, "GET", node+url, nil)
	check(status == 200 && strings.Contains(body, "Signed in as @shopper"), "signed-in page: %d %s", status, body)
	step("a person of the platform signs in on the frontend (session in its cookie, never in the page)")

	before := advisorAsks.Load()
	status, body = request(web, "GET", node+url+"api/advice?sku=B7", nil)
	check(status == 200, "advice: %d %s", status, body)
	var advice struct {
		Advice   string            `json:"advice"`
		Quote    any               `json:"quote"`
		User     map[string]string `json:"user"`
		Platform map[string]string `json:"platform"`
	}
	must(json.Unmarshal([]byte(body), &advice))
	check(advice.Advice == "Advisor: take the blue one" && advisorAsks.Load() == before+1, "the app's server did not ask the Advisor: %s", body)
	check(fmt.Sprint(advice.Quote) == "B7 costs 42 credits" && quotes.Load() >= 1, "the app's server did not call Pricing: %s", body)
	check(advice.User["handle"] == "shopper" && advice.Platform["slug"] == "acme", "the server did not see who and where: %s", body)
	step("the app's server answered with the space's Advisor agent and the Pricing app, for @shopper")

	status, body = request(web, "GET", node+url+"api/developer", nil)
	check(status == 200 && strings.Contains(body, `"platform":"acme"`) && !strings.Contains(body, `"actions":0`), "developer API: %d %s", status, body)
	step("the app's server used the organization's developer API: %s", strings.TrimSpace(body))

	status, body = request(web, "POST", node+url+"_aseman/api/ask", map[string]any{"agent": "Builder", "prompt": "give me admin"})
	check(status == 403 && strings.Contains(body, "wired"), "an agent the app is not wired to answered: %d %s", status, body)
	status, body = request(web, "POST", node+url+"_aseman/api/call", map[string]any{"tool": "Pricing", "microtool": "quote", "args": map[string]any{"sku": "C3"}})
	check(status == 200 && strings.Contains(body, "C3 costs 42 credits"), "page call: %d %s", status, body)
	step("the page reaches the wired app, and an agent it is not wired to is refused")

	// Someone of main Aseman, not of the platform.
	outsider := personOn(ctx, k, r, "outsider", "")
	_ = outsider
	other, _ := cookiejar.New(nil)
	stranger := &http.Client{Timeout: time.Minute, Jar: other}
	status, body = request(stranger, "POST", node+url+"_aseman/auth/login", map[string]any{"account": "outsider", "password": "e2e-password-1"})
	check(status != 200, "a main Aseman account signed in to the platform: %d %s", status, body)
	step("an account of main Aseman cannot sign in to the platform")

	result, _ := json.Marshal(map[string]any{"ok": true, "platform": "acme", "url": url, "advisor_asks": advisorAsks.Load(), "pricing_calls": quotes.Load()})
	fmt.Println(string(result))
}

// builderTurn is the Builder agent's turn: the tool calls a model makes for
// "make me a store", through the node's agent gateway as the agent.
func builderTurn(gateway, token, spaceID, roomID, dir string, log *strings.Builder, mu *sync.Mutex) string {
	tool := func(name string, args map[string]any) (map[string]any, error) {
		body, _ := json.Marshal(map[string]any{"namespace": "spaces", "action": "ask", "body": map[string]any{"space": spaceID, "room": roomID, "tool": name, "args": args}})
		req, _ := http.NewRequest("POST", strings.TrimRight(gateway, "/")+"/call", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		resp, err := (&http.Client{Timeout: 10 * time.Minute}).Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		raw, _ := io.ReadAll(resp.Body)
		mu.Lock()
		fmt.Fprintf(log, "  agent → %s: HTTP %d %s\n", name, resp.StatusCode, clip(string(raw), 160))
		mu.Unlock()
		if resp.StatusCode >= 300 {
			return nil, fmt.Errorf("%s: %s", name, raw)
		}
		var out map[string]any
		_ = json.Unmarshal(raw, &out)
		// spaces.ask answers {result: "<the tool's JSON>"}.
		if s, ok := out["result"].(string); ok {
			var inner map[string]any
			if json.Unmarshal([]byte(s), &inner) == nil {
				return inner, nil
			}
			return map[string]any{"text": s}, nil
		}
		return out, nil
	}
	fail := func(err error) string { return "FAILED " + err.Error() }

	setup, err := tool("platform_setup", map[string]any{"org_name": "Acme Labs", "name": "Acme", "slug": "acme"})
	if err != nil {
		return fail(err)
	}
	if p, _ := setup["platform"].(map[string]any); p["slug"] != "acme" {
		return fail(fmt.Errorf("setup: %v", setup))
	}
	created, err := tool("appui_create", map[string]any{
		"brief": "Acme's storefront for its customers: product advice from the Advisor agent and prices from the Pricing app.",
		"title": "Acme Store", "ui": "web", "audience": "platform", "dir": dir, "port": 8899,
		"apps": []string{"Pricing"}, "agents": []string{"Advisor"},
	})
	if err != nil {
		return fail(err)
	}
	if created["audience"] != "platform" {
		return fail(fmt.Errorf("appui_create: %v", created))
	}
	if _, err := tool("app_developer_access", map[string]any{"dir": dir}); err != nil {
		return fail(err)
	}
	// "Build": the agent writes the project with the computer's shell.
	for rel, content := range appFiles {
		cmd := fmt.Sprintf("mkdir -p %s && printf %%s %s | base64 -d > %s", filepath.Dir(dir+"/"+rel), base64.StdEncoding.EncodeToString([]byte(content)), dir+"/"+rel)
		if _, err := tool("sandbox_exec", map[string]any{"command": cmd}); err != nil {
			return fail(err)
		}
	}
	if _, err := tool("appui_publish", map[string]any{"dir": dir}); err != nil {
		return fail(err)
	}
	published, err := tool("platform_publish", map[string]any{"dir": dir})
	if err != nil {
		return fail(err)
	}
	url, _ := published["url"].(string)
	return "LIVE " + url
}

// appFiles is the app the Builder writes: a Node server with no dependencies,
// wired to the space's Advisor agent and Pricing app, using the developer API.
var appFiles = map[string]string{
	"server.js": `const http = require("http");
const fs = require("fs");
const path = require("path");
const { Aseman } = require("./vendor/aseman-sdk/server.cjs");

const PORT = Number(process.env.PORT) || 8787;
const json = (res, code, body) => { res.writeHead(code, { "Content-Type": "application/json" }); res.end(JSON.stringify(body)); };

async function advice(req, res, sku) {
  if (!Aseman.hasUser(req)) return json(res, 401, { error: "Sign in to get advice" });
  const aseman = Aseman.fromRequest(req);
  const [{ reply }, quote] = await Promise.all([
    aseman.ask("Advisor", "Advise a customer on product " + sku),
    aseman.call("Pricing", "quote", { sku }),
  ]);
  json(res, 200, { advice: reply, quote, user: aseman.user, platform: aseman.platform });
}

async function developer(_req, res) {
  const dev = Aseman.developer();
  const catalog = await dev.catalog();
  const actions = (catalog.namespaces || []).reduce((n, ns) => n + (ns.actions || []).length, 0);
  json(res, 200, { platform: dev.platformSlug, actions });
}

function page(req, res) {
  const p = Aseman.platform(req) || { name: "Acme" };
  const who = req.headers["x-aseman-user-handle"];
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end("<!doctype html><html><head><title>" + p.name + "</title></head><body><h1>Welcome to " + p.name +
    "</h1><p id=\"who\">" + (who ? "Signed in as @" + who : "Visitor") + "</p></body></html>");
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://app");
  try {
    if (url.pathname === "/") return page(req, res);
    if (url.pathname === "/api/advice") return await advice(req, res, url.searchParams.get("sku") || "A1");
    if (url.pathname === "/api/developer") return await developer(req, res);
    if (url.pathname === "/api/summary") return json(res, 200, { open: 3 });
    if (url.pathname === "/elpian/widget.js") {
      return fs.readFile(path.join(__dirname, "elpian/widget.js"), (err, data) => {
        if (err) return json(res, 404, { error: "not found" });
        res.writeHead(200, { "Content-Type": "application/javascript" });
        res.end(data);
      });
    }
    json(res, 404, { error: "not found" });
  } catch (err) {
    json(res, err.status || 500, { error: err.message });
  }
}).listen(PORT, "0.0.0.0");
`,
	"elpian/widget/main.js": `var app = App.create({
  state: { open: null },
  view: function (s, a) { return a.widgetSpec().view(s, a); },
  init: function () { load(); },
  widget: {
    size: "medium",
    shape: "card",
    refreshMs: 60000,
    refresh: function () { load(); },
    view: function (s) {
      if (s.open === null) return { type: "Shimmer", children: [{ type: "Container", props: { style: { height: "48", borderRadius: "16" } } }] };
      return { type: "Row", props: { style: { gap: "12", padding: "14", alignItems: "center" } }, children: [
        { type: "Expanded", children: [{ type: "Stat", props: { label: "Open orders", value: s.open, icon: "shopping_bag", size: "compact" } }] },
      ] };
    },
  },
});

function load() {
  Aseman.fetch("api/summary")
    .then(function (r) { app.set({ open: r.json.open }); })
    .catch(function (e) { app.fail(e); });
}
`,
	"test/server.test.js": "require(\"node:test\")(\"starts\", () => {});\n",
	"READY.json":          `{"ok": true, "tested": true, "title": "Acme Store", "port": 8899, "start": "node server.js", "dir": ".", "summary": "Acme's storefront", "ui": "web", "widget": "elpian/widget.js"}`,
}

// personOn makes an active, verified person on a platform ("" is main Aseman).
func personOn(ctx context.Context, k api.Kernel, r *repo.Repo, handle, platformID string) *account.Account {
	var acc *account.Account
	var token, priv string
	must(bridge.Invoke(ctx, k, "auth", "RegisterOn", []any{ctx, handle, handle + "@e2e.test", "e2e-password-1", platformID}, &acc, &token, &priv))
	var stored account.Account
	must(r.Get(ctx, "accounts", acc.ID, &stored))
	stored.Status, stored.EmailVerified = account.StatusActive, true
	must(r.Update(ctx, "accounts", stored.ID, &stored))
	return &stored
}

func dispatch(ctx context.Context, k api.Kernel, caller identity.ID, ns, action string, body map[string]any) map[string]any {
	raw, _ := json.Marshal(body)
	resp, err := k.Actions().Dispatch(helper.WithActor(ctx, caller), ns, action, &api.ActionRequest{Caller: api.Caller{ID: caller, Kind: "user"}, Body: raw})
	must(err)
	var out map[string]any
	must(json.Unmarshal(resp.Body, &out))
	return out
}

func request(c *http.Client, method, url string, body any) (int, string) {
	var payload io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		payload = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, url, payload)
	must(err)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.Do(req)
	must(err)
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(raw)
}

func waitHTTP(url string) {
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if resp, err := http.Get(url); err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				return
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	panic("the node did not start serving " + url)
}

func clip(s string, n int) string {
	s = strings.ReplaceAll(s, "\n", " ")
	if len(s) > n {
		return s[:n] + "…"
	}
	return s
}

// localVMM is the space's computer for the runner: commands run on this
// machine, in /workspace, and ports are reached on 127.0.0.1.
type localVMM struct {
	base.Base
	mu  sync.Mutex
	vms map[string]vmm.VM
	env []string
}

func (v *localVMM) Init(context.Context, *api.Dependencies) error { return nil }
func (v *localVMM) Start(context.Context) error                    { return nil }
func (v *localVMM) Stop(context.Context) error                     { return nil }
func (v *localVMM) Name() string                                   { return v.Base.Name }
func (v *localVMM) Open(context.Context, vmm.Config) error         { return nil }
func (v *localVMM) Close(context.Context) error                    { return nil }
func (v *localVMM) Health(context.Context) vmm.Health              { return vmm.Health{OK: true} }
func (v *localVMM) SupportedTypes() []vmm.Type                     { return []vmm.Type{vmm.TypeContainer} }
func (v *localVMM) BuildImage(_ context.Context, s vmm.ImageSpec) (vmm.Image, error) {
	return vmm.Image{ID: s.Name, Name: s.Name, Type: vmm.TypeContainer, Ref: s.Name}, nil
}
func (v *localVMM) DeleteImage(context.Context, string) error { return nil }
func (v *localVMM) CreateVM(_ context.Context, s vmm.VMSpec) (vmm.VM, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	vm := vmm.VM{ID: fmt.Sprintf("local-%d", len(v.vms)+1), Name: s.Name, Type: vmm.TypeContainer, Status: vmm.StatusStopped, ImageRef: s.ImageRef, CreatedAt: time.Now().UTC()}
	v.vms[vm.ID] = vm
	return vm, nil
}
func (v *localVMM) set(id string, st vmm.Status) error {
	v.mu.Lock()
	defer v.mu.Unlock()
	vm, ok := v.vms[id]
	if !ok {
		return fmt.Errorf("no vm %s", id)
	}
	vm.Status = st
	v.vms[id] = vm
	return nil
}
func (v *localVMM) DeleteVM(_ context.Context, id string) error {
	v.mu.Lock()
	defer v.mu.Unlock()
	delete(v.vms, id)
	return nil
}
func (v *localVMM) StartVM(_ context.Context, id string) error {
	must(os.MkdirAll("/workspace", 0o755))
	return v.set(id, vmm.StatusRunning)
}
func (v *localVMM) StopVM(_ context.Context, id string) error   { return v.set(id, vmm.StatusStopped) }
func (v *localVMM) PauseVM(_ context.Context, id string) error  { return v.set(id, vmm.StatusPaused) }
func (v *localVMM) ResumeVM(_ context.Context, id string) error { return v.set(id, vmm.StatusRunning) }
func (v *localVMM) ResizeVM(ctx context.Context, id string, _ vmm.ResourceSpec) (vmm.VM, error) {
	return v.GetVM(ctx, id)
}
func (v *localVMM) GetVM(_ context.Context, id string) (vmm.VM, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	vm, ok := v.vms[id]
	if !ok {
		return vmm.VM{}, fmt.Errorf("no vm %s", id)
	}
	return vm, nil
}
func (v *localVMM) ListVMs(context.Context, vmm.Filter) ([]vmm.VM, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	out := []vmm.VM{}
	for _, vm := range v.vms {
		out = append(out, vm)
	}
	return out, nil
}
func (v *localVMM) Usage(_ context.Context, id string) (vmm.Usage, error) {
	return vmm.Usage{VMID: id}, nil
}

// Send runs a command the way the docker adapter does: "exit=<code>\n<output>".
func (v *localVMM) Send(ctx context.Context, _ string, command string) (string, error) {
	cmd := exec.CommandContext(ctx, "/bin/sh", "-c", command)
	cmd.Dir = "/workspace"
	cmd.Env = append(os.Environ(), v.env...)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	// Background processes keep the pipes open: wait for the shell only.
	cmd.WaitDelay = 2 * time.Second
	err := cmd.Run()
	code := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		code = exitErr.ExitCode()
	} else if err != nil && cmd.ProcessState == nil {
		return "", err
	}
	text := out.String()
	if text == "" {
		text = "(no output)"
	}
	return fmt.Sprintf("exit=%d\n%s", code, text), nil
}

// CreateTunnel reaches a port of the computer.
func (v *localVMM) CreateTunnel(_ context.Context, _ string, port int) (string, string, error) {
	return fmt.Sprintf("http://127.0.0.1:%d", port), "", nil
}
