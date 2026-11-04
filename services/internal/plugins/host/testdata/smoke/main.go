// This runner executes separately from go test so native plugins and their
// host share ordinary packages compiled with identical flags.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
	"github.com/aseman/aseman/plugins/config"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}
func main() {
	root, err := os.Getwd()
	must(err)
	scratch, err := os.MkdirTemp("", "aseman-plugin-smoke-")
	must(err)
	defer os.RemoveAll(scratch)
	cfg := &dconfig.Config{Node: dconfig.NodeConfig{ID: "0000000000000001", Name: "smoke-admin", Central: true}, Plugins: dconfig.PluginsConfig{SourceRoot: root, Directory: filepath.Join(root, "bin/plugins"), Adapters: []dconfig.PluginSpec{{Name: "memory", Enabled: true}, {Name: "local-cache", Enabled: true}, {Name: "local", Enabled: true, Config: map[string]any{"base_path": filepath.Join(scratch, "files")}}}}}
	cfg.Defaults()
	must(os.Chdir(scratch))
	defer os.Chdir(root)
	application, err := app.New(cfg, map[string]string{"admin_password": "smoke-test-password"})
	must(err)
	defer application.Shutdown(context.Background())
	must(application.Bootstrap(context.Background()))
	k := application.K
	ctx, cancelRun := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancelRun()
	var admin *account.Account
	must(bridge.Invoke(ctx, k, "auth", "Account", []any{ctx, "smoke-admin"}, &admin))
	// Unauthenticated administration is rejected, including read-only inspection.
	if _, err := k.Actions().Dispatch(ctx, "admin", "plugins_list", &api.ActionRequest{}); err == nil {
		panic("anonymous administrator accepted")
	}
	// A namespace can be stopped, restarted and unloaded without stale routes.
	must(k.Stop("posts-ns"))
	if _, err := k.Resolve("service/posts"); err == nil {
		panic("stopped namespace resolved")
	}
	must(k.Start("posts-ns"))

	// Existing sessions can operate the fixed host while the auth/admin namespaces are stopped.
	var loginAccount *account.Account
	var token, privateKey string
	must(bridge.Invoke(ctx, k, "auth", "Login", []any{ctx, "smoke-admin", "smoke-test-password"}, &loginAccount, &token, &privateKey))
	must(k.Stop("auth-ns"))
	_, err = helper.SessionAccount(ctx, repo.New(k), token)
	must(err)
	controlRequest := &api.ActionRequest{Caller: api.Caller{ID: admin.ID, Kind: "user"}, Body: []byte(`{"name":"auth-ns"}`)}
	_, err = k.Control(ctx, "plugins_load", controlRequest)
	must(err)
	must(k.Unload("admin-ns"))
	controlRequest.Body = []byte(`{"path":"` + filepath.ToSlash(filepath.Join(root, "bin/plugins/actions/admin-ns.so")) + `"}`)
	_, err = k.Control(ctx, "plugins_load", controlRequest)
	must(err)
	_, err = k.Authenticate(ctx, token, true)
	must(err)
	must(k.Stop("memory"))
	_, err = k.Authenticate(ctx, token, true)
	must(err)
	controlRequest.Body = []byte(`{"name":"memory"}`)
	_, err = k.Control(ctx, "plugins_load", controlRequest)
	must(err)
	// A fake agent runtime exercises agent creation, direct asks, room
	// turns, provider resolution and turn tokens through dynamically loaded
	// modules.
	for _, name := range []string{"ASEMAN_LLM_BASE_URL", "ASEMAN_LLM_API_KEY", "ASEMAN_LLM_MODEL", "ASEMAN_IMAGE_MODEL"} {
		must(os.Unsetenv(name))
	}
	var turnsScoped atomic.Bool
	runtime := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Aseman-Runtime") != "smoke-secret" {
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
					Model string `json:"model"`
				} `json:"agent"`
				Turn vmm.AgentTurn `json:"turn"`
			}
			must(json.NewDecoder(r.Body).Decode(&turn))
			if turn.Token != "" && turn.Gateway != "" && turn.Agent.Model == "mock-model" && turn.Turn.SpaceID != "" && turn.Turn.Context != "" {
				turnsScoped.Store(true)
			}
			_, _ = w.Write([]byte(`{"reply":"plugin-agent-ok","status":"done"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer runtime.Close()
	_, err = k.LoadPlugin(ctx, filepath.Join(root, "bin/plugins/adapters/harness.so"), map[string]any{"options": map[string]string{"runtime_url": runtime.URL, "runtime_secret": "smoke-secret", "node_url": "http://127.0.0.1:1"}})
	must(err)
	must(bridge.Invoke(ctx, k, "llm", "SeedStatic", []any{ctx, vmm.ProviderConfig{Kind: "openai", BaseURL: runtime.URL, APIKey: "test-key", Model: "mock-model"}}))
	actorCtx := helper.WithActor(ctx, admin.ID)
	// Agent turns are metered: the asking account pays.
	must(bridge.Invoke(ctx, k, "finance", "Mint", []any{ctx, admin.ID, admin.ID, int64(1_000_000), "smoke credits"}, &json.RawMessage{}))
	var agent bot.Bot
	must(bridge.Invoke(actorCtx, k, "bots", "CreateBot", []any{actorCtx, admin.ID, map[string]any{"name": "smoke-agent", "kind": "agent", "vm_type": "harness", "instructions": "Reply briefly", "model": "mock-model"}}, &agent))
	must(bridge.Invoke(actorCtx, k, "bots", "Lifecycle", []any{actorCtx, agent.ID, "start"}, &agent))
	var reply string
	must(bridge.Invoke(actorCtx, k, "bots", "SendMessage", []any{actorCtx, agent.ID, "hello", []vmm.FileAttachment(nil), []vmm.ChatMessage(nil)}, &reply))
	if reply != "plugin-agent-ok" {
		panic(reply)
	}
	var home space.Space
	must(bridge.Invoke(actorCtx, k, "spaces", "HomeSpace", []any{actorCtx, admin.ID}, &home))
	must(bridge.Invoke(actorCtx, k, "spaces", "AddBot", []any{actorCtx, admin.ID, home.ID, identity.ID{}, agent.AccountID}))
	must(bridge.Invoke(actorCtx, k, "spaces", "AskBot", []any{actorCtx, home.ID, agent.ID, "hello", []vmm.FileAttachment(nil), []vmm.ChatMessage(nil)}, &reply))
	if reply != "plugin-agent-ok" || !turnsScoped.Load() {
		panic("agent turns are not scoped to their space")
	}
	// Build two isolated revisions and exercise replacement across DTO identities.
	adapterPath, err := k.BuildPlugin(ctx, "plugins/adapters/example", scratch)
	must(err)
	_, err = k.LoadPlugin(ctx, adapterPath, map[string]any{"prefix": "First"})
	must(err)
	greeterPath, err := k.BuildPlugin(ctx, "plugins/actions/greeter", scratch)
	must(err)
	_, err = k.LoadPlugin(ctx, greeterPath, nil)
	must(err)
	var out struct {
		Greeting string `json:"greeting"`
	}
	must(bridge.Invoke(ctx, k, "greeter", "Hello", []any{ctx, "Ada"}, &out))
	if out.Greeting != "First, Ada!" {
		panic(out.Greeting)
	}
	revision, err := k.BuildPlugin(ctx, "plugins/actions/greeter", scratch)
	must(err)
	_, err = k.ReplacePlugin(ctx, "greeter-ns", revision, nil)
	must(err)
	must(bridge.Invoke(ctx, k, "greeter", "Hello", []any{ctx, "Lin"}, &out))
	if out.Greeting != "First, Lin!" {
		panic(out.Greeting)
	}
	adapterRevision, err := k.BuildPlugin(ctx, "plugins/adapters/example", scratch)
	must(err)
	_, err = k.ReplacePlugin(ctx, "example-adapter", adapterRevision, map[string]any{"prefix": "Second"})
	must(err)
	must(bridge.Invoke(ctx, k, "greeter", "Hello", []any{ctx, "Ada"}, &out))
	if out.Greeting != "Second, Ada!" {
		panic(out.Greeting)
	}
	// Initialization failures must restore the previous provider and its configuration.
	if _, err = k.ReplacePlugin(ctx, "example-adapter", adapterRevision, map[string]any{"prefix": 123}); err == nil {
		panic("invalid provider configuration accepted")
	}
	must(bridge.Invoke(ctx, k, "greeter", "Hello", []any{ctx, "Ada"}, &out))
	if out.Greeting != "Second, Ada!" {
		panic("rollback lost provider configuration")
	}
	// Failed replacements leave the current plugin functional.
	if _, err = k.ReplacePlugin(ctx, "greeter-ns", adapterRevision, nil); err == nil {
		panic("incompatible replacement accepted")
	}
	must(bridge.Invoke(ctx, k, "greeter", "Hello", []any{ctx, "Ada"}, &out))
	must(k.Unload("greeter-ns"))
	if _, err = k.Actions().Dispatch(ctx, "greeter", "hello", &api.ActionRequest{Body: []byte(`{"name":"Ada"}`)}); err == nil {
		panic("unloaded action reachable")
	}
	_, err = k.LoadPlugin(ctx, greeterPath, nil)
	must(err)
	// Federation owns its peer routes, including unload and rebind on protocol restart.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	must(err)
	addr := listener.Addr().String()
	must(listener.Close())
	_, err = k.LoadPlugin(ctx, filepath.Join(root, "bin/plugins/adapters/http.so"), map[string]any{"addr": addr})
	must(err)
	serveCtx, stopServing := context.WithCancel(ctx)
	serveDone := make(chan error, 1)
	go func() { serveDone <- application.Serve(serveCtx) }()
	client := &http.Client{Timeout: time.Second}
	probe := func(path string, status int) {
		deadline := time.Now().Add(5 * time.Second)
		for {
			resp, err := client.Get("http://" + addr + path)
			if err == nil {
				_, _ = io.Copy(io.Discard, resp.Body)
				_ = resp.Body.Close()
				if resp.StatusCode == status {
					return
				}
			}
			if time.Now().After(deadline) {
				panic(fmt.Sprintf("route %s did not reach status %d: %v", path, status, err))
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
	probe("/healthz", 200)
	probe("/fed/dispatch", 401)
	must(k.Unload("federation-ns"))
	probe("/fed/dispatch", 404)
	_, err = k.LoadPlugin(ctx, filepath.Join(root, "bin/plugins/actions/federation-ns.so"), nil)
	must(err)
	probe("/fed/dispatch", 401)
	must(k.Update("http", map[string]any{"addr": addr}))
	probe("/healthz", 200)
	probe("/fed/dispatch", 401)
	stopServing()
	select {
	case err := <-serveDone:
		must(err)
	case <-time.After(5 * time.Second):
		panic("network supervisor did not drain")
	}
	// The core remains independent of namespace-owned model definitions.
	models := k.DB().Models()
	seen := map[string]bool{}
	for _, m := range models {
		seen[m.Name] = true
	}
	for _, name := range []string{"execution_events", "routines", "posts", "llm_providers"} {
		if !seen[name] {
			panic("missing namespace schema: " + name)
		}
	}
	// Keep an existing repository and replace the database provider. Its next
	// operation must use the new instance, with all registered schemas available.
	repository := repo.New(k)
	databasePath, err := k.BuildPlugin(ctx, "plugins/adapters/database/memory", scratch)
	must(err)
	_, err = k.ReplacePlugin(ctx, "memory", databasePath, nil)
	must(err)
	var count int64
	count, err = repository.DB.Count(ctx, "execution_events", database.Filter{})
	must(err)
	if count != 0 {
		panic("replacement memory database retained old records")
	}
	if len(k.DB().Models()) != len(models) {
		panic("database replacement lost schema registry")
	}
	shutdownCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	must(application.Shutdown(shutdownCtx))
	result, _ := json.Marshal(map[string]any{"ok": true, "namespaces": 14, "models": len(models), "native_replacement": true, "database_replacement": true, "agent_tools": true, "host_control": true, "federation_routes": true, "network_restart": true})
	fmt.Println(string(result))
}
