// This runner proves, on a whole node, that the developer API's workflow
// installer brings a product up from one document: it runs
// docs/workflows/fullstack-product.json from the console as a person — an
// organization with a member, its platform and server key, a project
// with rooms and agents, and a full-stack app written onto the project's
// computer, tested and served — checks what each step made, runs it again to
// show nothing is made twice, runs a workflow through the aseman CLI with an
// API key on the developer API, and rolls a failing one back.
//
// It boots the node as the platform runner does (every namespace a native
// plugin, the memory database, the HTTP adapter). The project's computer is
// this machine (/workspace), and a stand-in agents' runtime and model
// provider answer in this process: run it as root on a throwaway machine,
// after make plugins:
//
//	ASEMAN_WORKFLOW_E2E=1 go test ./internal/plugins/host -run WorkflowE2E
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/app"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
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

const appDir = "/workspace/apps/acme-bookings"

func main() {
	root, err := os.Getwd()
	must(err)
	repoRoot := filepath.Join(root, "..")
	kit := filepath.Join(repoRoot, "deploy", "sandbox-computer", "appui")
	scratch, err := os.MkdirTemp("", "aseman-workflow-e2e-")
	must(err)
	defer os.RemoveAll(scratch)
	defer os.RemoveAll("/workspace/apps")
	defer exec.Command("pkill", "-f", "python3 server.py").Run()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	must(err)
	addr := listener.Addr().String()
	must(listener.Close())
	node := "http://" + addr
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

	computer := &localVMM{Base: base.Base{Name: "local-sandbox", Category: api.CategoryVMM, Version: "1.0.0", Provides: []string{"vmm"}},
		vms: map[string]vmm.VM{}, env: []string{"ASEMAN_APPUI_ROOT=" + kit}}
	must(k.Register(computer))
	must(k.Init(computer.Info().Name))
	must(k.Start(computer.Info().Name))

	// The agents' runtime and the model provider, in one stand-in.
	var modelCalls sync.Map
	runtime := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasSuffix(r.URL.Path, "/chat/completions"):
			modelCalls.Store(time.Now().UnixNano(), r.URL.Path)
			_, _ = w.Write([]byte(`{"id":"c1","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"Welcome aboard, team Acme Bookings! Let's build something great."},"finish_reason":"stop"}],"usage":{"prompt_tokens":20,"completion_tokens":12}}`))
		case r.Header.Get("X-Aseman-Runtime") != "e2e-secret":
			w.WriteHeader(http.StatusUnauthorized)
		case r.URL.Path == "/healthz":
			_, _ = w.Write([]byte(`{"ok":true}`))
		case r.URL.Path == "/v1/questions":
			_, _ = w.Write([]byte(`{"questions":[]}`))
		case r.URL.Path == "/v1/turns":
			_, _ = w.Write([]byte(`{"reply":"ok","status":"done","answered":true}`))
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

	r := repo.New(k)
	person := personOn(ctx, k, r, "founder", "")
	teammate := personOn(ctx, k, r, "teammate", "")
	_ = teammate
	must(bridge.Invoke(ctx, k, "finance", "Mint", []any{ctx, person.ID, person.ID, int64(50_000_000), "e2e credits"}, &json.RawMessage{}))

	models := dispatch(ctx, k, person.ID, "developer", "models", map[string]any{})
	modelID := ""
	for _, m := range list(models["models"]) {
		if mm, _ := m.(map[string]any); mm["type"] == "language" && modelID == "" {
			modelID = fmt.Sprint(mm["id"])
		}
	}
	check(modelID != "", "the developer catalog has no language model: %v", models)
	step("a node with a person (credits), a teammate, and model %s", modelID)

	// 1. The documented example, from the console, as the person.
	doc, err := os.ReadFile(filepath.Join(repoRoot, "docs/workflows/fullstack-product.json"))
	must(err)
	inputs := map[string]any{"team": []any{"teammate"}, "model": modelID, "agent_model": "mock-model", "build_frontend": true}
	secrets := map[string]string{"SESSION_SECRET": "e2e-session-secret-value"}
	run := runConsole(ctx, k, person.ID, doc, inputs, secrets)
	report := run["report"].(map[string]any)
	printSteps(report)
	if run["status"] != "succeeded" {
		for _, e := range list(report["events"]) {
			fmt.Printf("  event %v\n", clip(mustJSON(e), 400))
		}
		fmt.Printf("  install request %v\n", clip(mustJSON(stepOf(report, "install")["request"]), 600))
	}
	check(run["status"] == "succeeded", "the example did not succeed: %v %v", run["status"], run["error"])
	outputs := report["outputs"].(map[string]any)
	org := fmt.Sprint(outputs["org"])
	spaceID := fmt.Sprint(outputs["space"])
	check(!strings.Contains(mustJSON(run), "e2e-session-secret-value"), "the secret reached the stored run")

	orgs := dispatch(ctx, k, person.ID, "developer", "orgs_list", map[string]any{})
	check(strings.Contains(mustJSON(orgs), `"name":"Acme Bookings"`), "no organization: %v", orgs)
	members := dispatch(ctx, k, person.ID, "developer", "members_list", map[string]any{"org": org})
	check(strings.Contains(mustJSON(members), `"handle":"teammate"`), "the teammate was not invited: %v", members)
	pf := dispatch(ctx, k, person.ID, "developer", "platform_get", map[string]any{"org": org})["platform"].(map[string]any)
	check(pf["slug"] == "acme-bookings", "platform: %v", pf)
	keys := dispatch(ctx, k, person.ID, "developer", "keys_list", map[string]any{"org": org})
	check(strings.Contains(mustJSON(keys), `"name":"acme-bookings-server"`) && strings.Contains(mustJSON(keys), `"platform":"write"`), "key: %v", keys)
	step("organization %s with @teammate invited, platform acme-bookings, server key", org)

	rooms := dispatch(ctx, k, person.ID, "spaces", "room_list", map[string]any{"space": spaceID})
	bots := dispatch(ctx, k, person.ID, "spaces", "bots_list", map[string]any{"space": spaceID})
	check(strings.Contains(mustJSON(rooms), `"Engineering"`) && strings.Contains(mustJSON(rooms), `"Support"`), "rooms: %v", rooms)
	check(strings.Contains(mustJSON(bots), `"Builder"`) && strings.Contains(mustJSON(bots), `"Concierge"`), "agents in the space: %v", bots)
	step("project %s with rooms Engineering and Support and agents Builder and Concierge", spaceID)

	for _, f := range []string{"server.py", "test_server.py", "public/index.html", "public/app.js", ".env", "aseman.json"} {
		_, err := os.Stat(filepath.Join(appDir, f))
		check(err == nil, "%s was not written: %v", f, err)
	}
	index, _ := os.ReadFile(filepath.Join(appDir, "public/index.html"))
	check(strings.Contains(string(index), "<title>Acme Bookings</title>"), "the template asset was not rendered: %s", index)
	env, _ := os.ReadFile(filepath.Join(appDir, ".env"))
	check(strings.Contains(string(env), "SESSION_SECRET=e2e-session-secret-value"), "the secret did not reach the app's settings")
	info, _ := os.Stat(filepath.Join(appDir, "server.py"))
	check(info != nil && info.Mode()&0o100 != 0, "server.py is not executable")
	status, body := request(http.DefaultClient, "POST", "http://127.0.0.1:8080/api/bookings", map[string]any{"name": "Ada"})
	check(status == 201, "the app does not take bookings: %d %s", status, body)
	status, body = request(http.DefaultClient, "GET", "http://127.0.0.1:8080/api/bookings", nil)
	check(status == 200 && strings.Contains(body, "Ada"), "the app does not list bookings: %d %s", status, body)
	preview := fmt.Sprint(outputs["preview"])
	check(strings.HasPrefix(preview, "/v1/proxy/"), "no preview: %v", outputs)
	step("the app's source is on the computer, its tests passed, and it serves (preview %s)", preview)

	welcome := stepOf(report, "welcome")
	frontend := stepOf(report, "frontend")
	check(welcome["status"] == "succeeded", "the model step failed: %v", welcome["error"])
	check(frontend["status"] == "succeeded", "asking the Builder for the frontend failed: %v", frontend["error"])
	msgs := dispatch(ctx, k, person.ID, "spaces", "message_list", map[string]any{"space": spaceID, "limit": 20})
	check(strings.Contains(mustJSON(msgs), "Welcome aboard"), "the welcome was not posted: %s", clip(mustJSON(msgs), 400))
	step("a model wrote the welcome, it was posted in the project, and the Builder agent was asked for the frontend")

	// 2. Again: nothing is made twice.
	again := runConsole(ctx, k, person.ID, doc, inputs, secrets)
	counts := again["report"].(map[string]any)["counts"].(map[string]any)
	check(again["status"] == "succeeded" && counts["created"] == 0.0, "the rerun: %v created=%v\n%s", again["status"], counts["created"], stepsText(again["report"].(map[string]any)))
	bots2 := dispatch(ctx, k, person.ID, "bots", "bot_list", map[string]any{"limit": 200})
	check(strings.Count(mustJSON(bots2), `"name":"Builder"`) == 1, "an agent was made twice")
	step("running it again created nothing (%v unchanged, %v updated)", counts["unchanged"], counts["updated"])

	// 3. A key's workflow, through the aseman CLI, on the developer API.
	made := dispatch(ctx, k, person.ID, "developer", "key_create", map[string]any{"org": org, "input": map[string]any{"name": "ci", "permissions": map[string]any{"platform": "write"}}})
	key := fmt.Sprint(made["secret"])
	small := filepath.Join(scratch, "key-workflow.json")
	must(os.WriteFile(small, []byte(`{"aseman_workflow":"1","name":"from-ci",
	  "inputs":{"name":{"type":"string","required":true}},
	  "steps":[
	    {"id":"space","upsert":{"resource":"space","with":{"name":"${{ inputs.name }}"}}},
	    {"id":"hello","sandbox":{"space":"${{ steps.space.outputs.id }}","start":true,"root":"apps/ci","files":{"hello.txt":"hi"},"exec":{"run":"cat hello.txt","expect":"hi"}}}
	  ],"outputs":{"space":"${{ steps.space.outputs.id }}"}}`), 0o644))
	cli := func(args ...string) (string, error) {
		cmd := exec.Command("go", append([]string{"run", "./cmd/aseman", "workflow"}, args...)...)
		cmd.Dir = root
		var out bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &out
		err := cmd.Run()
		return out.String(), err
	}
	out, err := cli("run", small, "name=CI Space", "--key", key, "--api", node+"/dev/v1")
	fmt.Print(indent(out))
	check(err == nil && strings.Contains(out, "succeeded"), "the CLI run: %v", err)
	var ciSpace string
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "space = ") {
			ciSpace = strings.Trim(strings.TrimSpace(strings.SplitN(line, "=", 2)[1]), `"`)
		}
	}
	stamped := spacePlatform(ctx, r, ciSpace)
	check(stamped == fmt.Sprint(pf["id"]), "the key's space is not on the organization's platform: %q vs %v", stamped, pf["id"])
	bad := filepath.Join(scratch, "bad.json")
	must(os.WriteFile(bad, []byte(`{"aseman_workflow":"1","name":"bad","steps":[{"action":"developer.key_create"},{"action":"admin.health"}]}`), 0o644))
	out, err = cli("validate", bad, "--key", key, "--api", node+"/dev/v1")
	check(err != nil && strings.Contains(out, "managed from the console") && strings.Contains(out, "node administration"), "validate: %v %s", err, out)
	step("the CLI ran a workflow with an API key on the developer API (space on the platform), and refused one that manages keys")

	// 4. A failing run rolls back what it made.
	failing := []byte(`{"aseman_workflow":"1","name":"doomed","options":{"rollback_on_failure":true},"steps":[
	  {"id":"space","upsert":{"resource":"space","with":{"name":"Doomed"}}},
	  {"id":"room","upsert":{"resource":"room","with":{"space":"${{ steps.space.outputs.id }}","name":"Lobby"}}},
	  {"fail":"stop"}]}`)
	failed := runConsole(ctx, k, person.ID, failing, nil, nil)
	check(failed["status"] == "rolled_back", "rollback: %v %v", failed["status"], failed["error"])
	spaces := dispatch(ctx, k, person.ID, "spaces", "space_list", map[string]any{"kind": "all", "limit": 200})
	check(!strings.Contains(mustJSON(spaces), `"Doomed"`), "the rolled back space is still there")
	step("a failing run deleted, newest first, what it had made")

	fmt.Println(mustJSON(map[string]any{"ok": true, "org": org, "space": spaceID, "preview": preview}))
}

func runConsole(ctx context.Context, k api.Kernel, person identity.ID, doc []byte, inputs map[string]any, secrets map[string]string) map[string]any {
	out := dispatch(ctx, k, person, "developer", "workflow_run", map[string]any{"workflow": json.RawMessage(doc), "inputs": inputs, "secrets": secrets, "async": true})
	id := fmt.Sprint(out["id"])
	deadline := time.Now().Add(10 * time.Minute)
	for time.Now().Before(deadline) {
		got := dispatch(ctx, k, person, "developer", "workflow_run_get", map[string]any{"id": id})
		if got["status"] != "running" {
			return got
		}
		time.Sleep(200 * time.Millisecond)
	}
	panic("the workflow did not finish")
}

func stepOf(report map[string]any, id string) map[string]any {
	for _, s := range list(report["steps"]) {
		if m, _ := s.(map[string]any); m["path"] == id {
			return m
		}
	}
	return map[string]any{}
}

func stepsText(report map[string]any) string {
	var b strings.Builder
	for _, s := range list(report["steps"]) {
		m, _ := s.(map[string]any)
		fmt.Fprintf(&b, "  %-10v %-26v %v %v %v\n", m["status"], m["path"], m["action"], m["operation"], clip(fmt.Sprint(m["error"]), 300))
	}
	return b.String()
}

func printSteps(report map[string]any) { fmt.Print(stepsText(report)) }

func spacePlatform(ctx context.Context, r *repo.Repo, id string) string {
	sid, err := identity.Parse(id)
	if err != nil {
		return ""
	}
	var row struct {
		PlatformID string `db:"platform_id" json:"platform_id"`
	}
	if err := r.Get(ctx, "spaces", sid, &row); err != nil {
		return ""
	}
	return row.PlatformID
}

func list(v any) []any {
	l, _ := v.([]any)
	return l
}

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

func indent(s string) string {
	return "    " + strings.ReplaceAll(strings.TrimRight(s, "\n"), "\n", "\n    ") + "\n"
}

var _ = account.KindUser

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
	out, err := tryDispatch(ctx, k, caller, ns, action, body)
	must(err)
	return out
}

func tryDispatch(ctx context.Context, k api.Kernel, caller identity.ID, ns, action string, body map[string]any) (map[string]any, error) {
	raw, _ := json.Marshal(body)
	resp, err := k.Actions().Dispatch(helper.WithActor(ctx, caller), ns, action, &api.ActionRequest{Caller: api.Caller{ID: caller, Kind: "user"}, Body: raw})
	if err != nil {
		return nil, err
	}
	var out map[string]any
	if err := json.Unmarshal(resp.Body, &out); err != nil {
		return nil, err
	}
	return out, nil
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
func (v *localVMM) Start(context.Context) error                   { return nil }
func (v *localVMM) Stop(context.Context) error                    { return nil }
func (v *localVMM) Name() string                                  { return v.Base.Name }
func (v *localVMM) Open(context.Context, vmm.Config) error        { return nil }
func (v *localVMM) Close(context.Context) error                   { return nil }
func (v *localVMM) Health(context.Context) vmm.Health             { return vmm.Health{OK: true} }
func (v *localVMM) SupportedTypes() []vmm.Type                    { return []vmm.Type{vmm.TypeContainer} }
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
