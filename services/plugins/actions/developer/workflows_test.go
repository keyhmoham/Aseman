package developer

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/actions/developer/workflow"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// fakeSpaces stands in for the spaces namespace: enough of it for a
// workflow to upsert a space, write files and run a command.
type fakeSpaces struct {
	mu       sync.Mutex
	spaces   []map[string]any
	platform []string // the platform each space was stamped with
	callers  []string
	files    map[string]string
	commands []string
}

func (f *fakeSpaces) register(t *testing.T, fx *fixture) {
	t.Helper()
	f.files = map[string]string{}
	handle := func(name string, fn func(ctx context.Context, req *api.ActionRequest, in map[string]any) any) {
		err := fx.s.K.Actions().Register("spaces", helper.Action{Namespace: "spaces", Name: name, Summary: name,
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				var in map[string]any
				_ = json.Unmarshal(req.Body, &in)
				f.mu.Lock()
				defer f.mu.Unlock()
				f.callers = append(f.callers, req.Caller.ID.String())
				return helper.JSON(fn(ctx, req, in))
			}})
		if err != nil {
			t.Fatal(err)
		}
	}
	handle("space_list", func(context.Context, *api.ActionRequest, map[string]any) any {
		list := make([]any, len(f.spaces))
		for i, s := range f.spaces {
			list[i] = s
		}
		return map[string]any{"spaces": list}
	})
	handle("space_create", func(ctx context.Context, _ *api.ActionRequest, in map[string]any) any {
		id := "sp" + itoa(len(f.spaces)+1)
		f.spaces = append(f.spaces, map[string]any{"id": id, "name": in["name"], "description": in["description"]})
		p, _ := helper.ContextPlatform(ctx)
		f.platform = append(f.platform, p)
		return map[string]any{"space_id": id}
	})
	handle("sandbox_files", func(_ context.Context, _ *api.ActionRequest, in map[string]any) any {
		f.files[in["path"].(string)] = in["content"].(string)
		return map[string]any{"ok": true}
	})
	handle("sandbox_exec", func(_ context.Context, _ *api.ActionRequest, in map[string]any) any {
		f.commands = append(f.commands, in["command"].(string))
		return map[string]any{"output": "built\n__ASEMAN_WORKFLOW_EXIT=0\n"}
	})
	if err := fx.s.K.Actions().Register("admin", helper.Action{Namespace: "admin", Name: "health", Handler: func(context.Context, *api.ActionRequest) (*api.ActionResponse, error) {
		return helper.JSON(map[string]any{"ok": true})
	}}); err != nil {
		t.Fatal(err)
	}
	for _, a := range BuildActions(fx.s) {
		if err := fx.s.K.Actions().Register("developer", a); err != nil {
			t.Fatal(err)
		}
	}
}

func (f *fixture) door(t *testing.T, method network.Method, path, secret, body string) (*network.Response, map[string]any) {
	t.Helper()
	for _, r := range f.s.routes() {
		if r.method != method || !matchPattern(r.pattern, apiPrefix+path) {
			continue
		}
		req := &network.Request{Method: method, Path: apiPrefix + path, Header: map[string]string{"Authorization": "Bearer " + secret, "Content-Type": "application/json"}, Body: []byte(body)}
		pp, ap := strings.Split(r.pattern, "/"), strings.Split(apiPrefix+path, "/")
		params := map[string]string{}
		for i := range pp {
			if strings.HasPrefix(pp[i], "{") {
				params[strings.Trim(pp[i], "{}")] = ap[i]
			}
		}
		b, _ := json.Marshal(params)
		req.Header["x-route-params"] = string(b)
		resp, err := r.handler(f.ctx, req)
		if err != nil {
			t.Fatal(err)
		}
		var out map[string]any
		_ = json.Unmarshal(resp.Body, &out)
		return resp, out
	}
	t.Fatalf("no route %s %s", method, path)
	return nil, nil
}

const installer = `{
  "aseman_workflow": "1",
  "name": "shop",
  "inputs": {"product": {"type": "string", "default": "Shop"}},
  "secrets": ["DB_PASSWORD"],
  "steps": [
    {"id": "platform", "upsert": {"resource": "platform", "with": {"name": "${{ inputs.product }}", "slug": "${{ slug(inputs.product) }}"}}},
    {"id": "space", "upsert": {"resource": "space", "with": {"name": "${{ inputs.product }}"}}},
    {"id": "install", "sandbox": {"space": "${{ steps.space.outputs.id }}", "root": "app",
      "files": {"main.py": "print('hi')"}, "env": {"DB_PASSWORD": "${{ secrets.DB_PASSWORD }}"}, "exec": "python -m build"}}
  ],
  "outputs": {"platform": "${{ steps.platform.outputs.id }}", "space": "${{ steps.space.outputs.id }}"}
}`

func runBody(t *testing.T, doc string, extra map[string]any) string {
	t.Helper()
	body := map[string]any{"workflow": json.RawMessage(doc), "secrets": map[string]string{"DB_PASSWORD": "hunter2-very-secret"}}
	for k, v := range extra {
		body[k] = v
	}
	b, _ := json.Marshal(body)
	return string(b)
}

func TestWorkflowInstallerOnTheDeveloperHost(t *testing.T) {
	f := harness(t)
	fake := &fakeSpaces{}
	fake.register(t, f)
	_, secret := f.key(t, f.personal(t), KeyInput{Name: "installer", Permissions: Permissions{Platform: LevelWrite}})

	// Validation names what is wrong before anything runs.
	_, v := f.door(t, network.MethodPost, "/workflows/validate", secret, runBody(t, `{"aseman_workflow":"1","name":"x","steps":[
	  {"action":"admin.health"},{"action":"developer.key_create"},{"action":"spaces.space_teleport"}]}`, nil))
	issues := jsonString(v["issues"])
	if v["valid"] != false || !strings.Contains(issues, "node administration") || !strings.Contains(issues, "managed from the console") || !strings.Contains(issues, "no such action") {
		t.Fatalf("validate: %v", v)
	}

	// The plan reads, and changes nothing.
	resp, plan := f.door(t, network.MethodPost, "/workflows/plan", secret, runBody(t, installer, nil))
	if resp.Status != 200 || plan["status"] != "planned" || len(fake.spaces) != 0 {
		t.Fatalf("plan: %d %v", resp.Status, plan)
	}

	resp, run := f.door(t, network.MethodPost, "/workflows/runs", secret, runBody(t, installer, nil))
	if resp.Status != 200 || run["status"] != "succeeded" {
		t.Fatalf("run: %d %s", resp.Status, resp.Body)
	}
	p, _ := f.s.PlatformOfOrg(f.ctx, f.me)
	if p == nil || p.Slug != "shop" {
		t.Fatalf("the platform was made through the developer namespace: %+v", p)
	}
	if len(fake.spaces) != 1 || fake.platform[0] != p.ID.String() {
		t.Fatalf("a key's workflow stamps what it makes with the org's platform: %v %v", fake.spaces, fake.platform)
	}
	for _, c := range fake.callers {
		if c != f.me.String() {
			t.Fatalf("every call acts as the person behind the key: %v", fake.callers)
		}
	}
	if fake.files["/workspace/app/main.py"] != "print('hi')" || !strings.Contains(fake.commands[0], "export DB_PASSWORD='hunter2-very-secret'") {
		t.Fatalf("install: %v %v", fake.files, fake.commands)
	}
	// The secret is in neither the stored run nor the request log.
	var runs []models.WorkflowRun
	_ = f.s.R.List(f.ctx, "dev_workflow_runs", database.Filter{}, &runs)
	var logs []models.Log
	_ = f.s.R.List(f.ctx, "dev_logs", database.Filter{}, &logs)
	if len(runs) != 2 || strings.Contains(jsonOf(runs), "hunter2") || strings.Contains(jsonOf(logs), "hunter2") || strings.Contains(string(resp.Body), "hunter2") {
		t.Fatalf("a secret leaked: runs=%d", len(runs))
	}

	// Again, asynchronously: nothing new is made, and the run can be read back.
	resp, async := f.door(t, network.MethodPost, "/workflows/runs", secret, runBody(t, installer, map[string]any{"async": true}))
	if resp.Status != 202 {
		t.Fatalf("async: %d %s", resp.Status, resp.Body)
	}
	id := async["id"].(string)
	var got map[string]any
	for i := 0; i < 200; i++ {
		_, got = f.door(t, network.MethodGet, "/workflows/runs/"+id, secret, "")
		if got["status"] != "running" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if got["status"] != "succeeded" || len(fake.spaces) != 1 {
		t.Fatalf("async run: %v spaces=%d", got["status"], len(fake.spaces))
	}
	if !strings.Contains(jsonString(got["report"]), `"operation":"unchanged"`) {
		t.Fatalf("a rerun leaves what exists alone: %s", jsonString(got["report"]))
	}
	if resp, schema := f.door(t, network.MethodGet, "/workflows/schema", secret, ""); resp.Status != 200 || schema["$id"] != workflow.SchemaID {
		t.Fatalf("schema: %d", resp.Status)
	}
	_, list := f.door(t, network.MethodGet, "/workflows/runs", secret, "")
	if data, _ := list["data"].([]any); len(data) != 3 {
		t.Fatalf("list: %v", list)
	}

	// A read-only key may read runs but not start them.
	_, ro := f.key(t, f.personal(t), KeyInput{Name: "reader", Permissions: Permissions{Platform: LevelRead}})
	if resp, _ := f.door(t, network.MethodPost, "/workflows/runs", ro, runBody(t, installer, nil)); resp.Status != 403 {
		t.Fatalf("read-only key: %d", resp.Status)
	}
	// Another organization's run is not there.
	team, _ := f.s.CreateOrg(f.ctx, f.me, "Other")
	tsc, _ := f.s.Scope(f.ctx, f.me, team.ID)
	_, other := f.key(t, tsc, KeyInput{Name: "other", Permissions: Permissions{Platform: LevelWrite}})
	if resp, _ := f.door(t, network.MethodGet, "/workflows/runs/"+id, other, ""); resp.Status != 404 {
		t.Fatalf("cross-org read: %d", resp.Status)
	}
}

func TestWorkflowFromTheConsole(t *testing.T) {
	f := harness(t)
	fake := &fakeSpaces{}
	fake.register(t, f)
	call := func(name string, body map[string]any) (map[string]any, error) {
		b, _ := json.Marshal(body)
		resp, err := f.s.K.Actions().Dispatch(f.ctx, "developer", name, &api.ActionRequest{Caller: api.Caller{ID: f.me, Kind: "user"}, Body: b})
		if err != nil {
			return nil, err
		}
		var out map[string]any
		_ = json.Unmarshal(resp.Body, &out)
		return out, nil
	}
	// The console may also manage the organization: a team, its key, its
	// platform — and the spaces are not stamped unless asked.
	doc := `{"aseman_workflow":"1","name":"team","steps":[
	  {"id":"org","upsert":{"resource":"org","with":{"name":"Acme"}}},
	  {"id":"key","upsert":{"resource":"key","with":{"org":"${{ steps.org.outputs.id }}","name":"server","permissions":{"platform":"write"}}}},
	  {"id":"platform","upsert":{"resource":"platform","with":{"org":"${{ steps.org.outputs.id }}","name":"Acme","slug":"acme"}}},
	  {"id":"space","upsert":{"resource":"space","with":{"name":"Acme HQ"}}}
	],"outputs":{"secret":"${{ steps.key.outputs.result.secret }}","org":"${{ steps.org.outputs.id }}"}}`
	out, err := call("workflow_run", map[string]any{"workflow": json.RawMessage(doc)})
	if err != nil || out["status"] != "succeeded" {
		t.Fatalf("console run: %v %v", err, out)
	}
	rep := out["report"].(map[string]any)
	outputs := rep["outputs"].(map[string]any)
	if outputs["secret"] != "••••••" {
		t.Fatalf("a key's secret is redacted from the report: %v", outputs)
	}
	sc, err := f.s.Scope(f.ctx, f.me, outputs["org"].(string))
	if err != nil {
		t.Fatal(err)
	}
	if keys, _ := f.s.Keys(f.ctx, sc); len(keys) != 1 || keys[0].Permissions.Platform != LevelWrite {
		t.Fatalf("keys: %+v", keys)
	}
	if p, _ := f.s.PlatformOfOrg(f.ctx, sc.Org); p == nil || p.Slug != "acme" {
		t.Fatalf("platform: %+v", p)
	}
	if fake.platform[0] != "" {
		t.Fatalf("console spaces are not stamped unless stamp_platform: %v", fake.platform)
	}
	// Rerunning finds the organization, the key and the platform.
	out, _ = call("workflow_run", map[string]any{"workflow": json.RawMessage(doc)})
	counts, _ := out["report"].(map[string]any)["counts"].(map[string]any)
	if out["status"] != "succeeded" || counts["unchanged"] != 4.0 || counts["created"] != 0.0 {
		t.Fatalf("rerun: %v", counts)
	}
	ref, _ := call("workflow_reference", map[string]any{})
	if _, ok := ref["presets"].(map[string]any)["agent"]; !ok {
		t.Fatalf("reference: %v", ref)
	}
	runs, _ := call("workflow_runs", map[string]any{})
	if l, _ := runs["runs"].([]any); len(l) != 2 {
		t.Fatalf("runs: %v", runs)
	}
}

func TestWorkflowCancelFromAnotherNode(t *testing.T) {
	f := harness(t)
	fake := &fakeSpaces{}
	fake.register(t, f)
	defer func(h time.Duration) { workflowHeartbeat = h }(workflowHeartbeat)
	workflowHeartbeat = 5 * time.Millisecond
	started := make(chan struct{}, 1)
	if err := f.s.K.Actions().Register("spaces", helper.Action{Namespace: "spaces", Name: "block", Handler: func(ctx context.Context, _ *api.ActionRequest) (*api.ActionResponse, error) {
		started <- struct{}{}
		<-ctx.Done()
		return nil, ctx.Err()
	}}); err != nil {
		t.Fatal(err)
	}
	_, secret := f.key(t, f.personal(t), KeyInput{Name: "w", Permissions: Permissions{Platform: LevelWrite}})
	doc := `{"aseman_workflow":"1","name":"long","steps":[{"id":"b","action":"spaces.block"}]}`
	body := runBody(t, doc, map[string]any{"async": true})
	ids := []string{}
	for i := 0; i < MaxActiveWorkflows; i++ {
		resp, out := f.door(t, network.MethodPost, "/workflows/runs", secret, body)
		if resp.Status != 202 {
			t.Fatalf("start %d: %d %s", i, resp.Status, resp.Body)
		}
		ids = append(ids, out["id"].(string))
		<-started
	}
	if resp, _ := f.door(t, network.MethodPost, "/workflows/runs", secret, body); resp.Status != 409 {
		t.Fatalf("a fourth run at once is refused: %d", resp.Status)
	}
	// Pretend the first run is on another node: this one no longer holds it.
	mu, active := f.s.wfActive()
	mu.Lock()
	var key string
	for k := range active {
		if strings.HasSuffix(k, ids[0]) {
			key = k
		}
	}
	elsewhere := active[key]
	delete(active, key)
	mu.Unlock()
	defer elsewhere()
	resp, out := f.door(t, network.MethodPost, "/workflows/runs/"+ids[0]+"/cancel", secret, "")
	if resp.Status != 200 || out["status"] != "cancelling" {
		t.Fatalf("cancel: %d %v", resp.Status, out)
	}
	for _, id := range ids[1:] {
		f.door(t, network.MethodPost, "/workflows/runs/"+id+"/cancel", secret, "")
	}
	for _, id := range ids {
		var got map[string]any
		for i := 0; i < 500; i++ {
			_, got = f.door(t, network.MethodGet, "/workflows/runs/"+id, secret, "")
			if got["status"] != "running" {
				break
			}
			time.Sleep(5 * time.Millisecond)
		}
		if got["status"] != "cancelled" {
			t.Fatalf("run %s: %v", id, got["status"])
		}
	}
	var asks []models.WorkflowCancel
	_ = f.s.R.List(f.ctx, "dev_workflow_cancels", database.Filter{}, &asks)
	if len(asks) != 0 {
		t.Fatalf("a cancel request is cleared with its run: %v", asks)
	}
}

func TestASynchronousRunAnswersBeforeTheProxyGivesUp(t *testing.T) {
	f := harness(t)
	fake := &fakeSpaces{}
	fake.register(t, f)
	defer func(w time.Duration) { workflowSyncWait = w }(workflowSyncWait)
	workflowSyncWait = 20 * time.Millisecond
	release := make(chan struct{})
	if err := f.s.K.Actions().Register("spaces", helper.Action{Namespace: "spaces", Name: "slow", Handler: func(ctx context.Context, _ *api.ActionRequest) (*api.ActionResponse, error) {
		<-release
		return helper.JSON(map[string]any{"ok": true})
	}}); err != nil {
		t.Fatal(err)
	}
	_, secret := f.key(t, f.personal(t), KeyInput{Name: "w", Permissions: Permissions{Platform: LevelWrite}})
	resp, out := f.door(t, network.MethodPost, "/workflows/runs", secret, runBody(t, `{"aseman_workflow":"1","name":"slow","steps":[{"action":"spaces.slow"}]}`, nil))
	if resp.Status != 202 || out["status"] != "running" {
		t.Fatalf("a run past the wait answers 202: %d %v", resp.Status, out)
	}
	close(release)
	var got map[string]any
	for i := 0; i < 500; i++ {
		_, got = f.door(t, network.MethodGet, "/workflows/runs/"+out["id"].(string), secret, "")
		if got["status"] != "running" {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if got["status"] != "succeeded" {
		t.Fatalf("it finishes on its own: %v", got["status"])
	}
}
