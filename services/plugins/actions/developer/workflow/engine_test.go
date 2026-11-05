package workflow

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakePlatform is an in-memory stand-in for the node's actions.
type fakePlatform struct {
	mu       sync.Mutex
	seq      int
	spaces   []map[string]any
	bots     []map[string]any
	members  map[string][]string // space → bot ids
	files    map[string]string   // space:path → content
	commands []string
	proxies  []map[string]any
	orgs     []map[string]any
	platform map[string]any
	keys     []map[string]any
	calls    []string
	running  map[string]int // space → status polls until running
	fail     map[string]int // action → failures left
	failErr  error
	deleted  []string
	models   []map[string]any
}

type codedErr struct{ code, msg string }

func (e *codedErr) Error() string { return e.msg }

func newFake() *fakePlatform {
	return &fakePlatform{members: map[string][]string{}, files: map[string]string{}, running: map[string]int{}, fail: map[string]int{}}
}

func (f *fakePlatform) id(prefix string) string {
	f.seq++
	return fmt.Sprintf("%s%d", prefix, f.seq)
}

func (f *fakePlatform) Model(_ context.Context, typ string, body map[string]any) (any, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.models = append(f.models, body)
	return map[string]any{"text": "hello from " + ToString(body["model"]), "type": typ}, nil
}

func (f *fakePlatform) Call(_ context.Context, action string, with map[string]any) (any, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, action)
	if n := f.fail[action]; n > 0 {
		f.fail[action] = n - 1
		if f.failErr != nil {
			return nil, f.failErr
		}
		return nil, &codedErr{"unavailable", "temporarily unavailable"}
	}
	s := func(k string) string { return ToString(with[k]) }
	switch action {
	case "spaces.space_list":
		return map[string]any{"spaces": copyList(f.spaces)}, nil
	case "spaces.space_create":
		id := f.id("sp")
		f.spaces = append(f.spaces, map[string]any{"id": id, "name": s("name"), "description": s("description")})
		return map[string]any{"space_id": id, "name": s("name"), "room_id": "room-" + id}, nil
	case "spaces.space_update":
		for _, sp := range f.spaces {
			if sp["id"] == s("space") {
				if v := s("name"); v != "" {
					sp["name"] = v
				}
				if v := s("description"); v != "" {
					sp["description"] = v
				}
				return map[string]any{"ok": true}, nil
			}
		}
		return nil, &codedErr{"not_found", "space"}
	case "spaces.space_delete":
		f.deleted = append(f.deleted, "space:"+s("space"))
		out := f.spaces[:0]
		for _, sp := range f.spaces {
			if sp["id"] != s("space") {
				out = append(out, sp)
			}
		}
		f.spaces = out
		return map[string]any{"ok": true}, nil
	case "bots.bot_list":
		return map[string]any{"bots": copyList(f.bots)}, nil
	case "bots.bot_create":
		if s("name") == "" {
			return nil, &codedErr{"invalid_argument", "a bot needs a name"}
		}
		id := f.id("bot")
		f.bots = append(f.bots, map[string]any{"id": id, "name": s("name"), "kind": s("kind"), "model": s("model")})
		return map[string]any{"bot_id": id, "name": s("name"), "status": "running"}, nil
	case "bots.bot_edit":
		for _, b := range f.bots {
			if b["id"] == s("bot") {
				for k, v := range with {
					if k != "bot" {
						b[k] = v
					}
				}
				return map[string]any{"ok": true}, nil
			}
		}
		return nil, &codedErr{"not_found", "bot"}
	case "bots.bot_delete":
		f.deleted = append(f.deleted, "bot:"+s("bot"))
		return map[string]any{"ok": true}, nil
	case "spaces.bots_list":
		var out []any
		for _, id := range f.members[s("space")] {
			out = append(out, map[string]any{"id": id})
		}
		return map[string]any{"bots": out}, nil
	case "spaces.bot_add":
		f.members[s("space")] = append(f.members[s("space")], s("bot"))
		return map[string]any{"ok": true}, nil
	case "spaces.bot_remove":
		f.deleted = append(f.deleted, "member:"+s("bot"))
		return map[string]any{"ok": true}, nil
	case "spaces.sandbox_start":
		return map[string]any{"status": "starting"}, nil
	case "spaces.sandbox_status":
		if f.running[s("space")] > 0 {
			f.running[s("space")]--
			return map[string]any{"status": "starting"}, nil
		}
		return map[string]any{"status": "running"}, nil
	case "spaces.sandbox_files":
		key := s("space") + ":" + s("path")
		switch s("operation") {
		case "write":
			if b := s("data_base64"); b != "" {
				f.files[key] = "b64:" + b
			} else {
				f.files[key] = s("content")
			}
		case "delete":
			for k := range f.files {
				if strings.HasPrefix(k, key) {
					delete(f.files, k)
				}
			}
		}
		return map[string]any{"ok": true}, nil
	case "spaces.sandbox_exec":
		cmd := s("command")
		f.commands = append(f.commands, cmd)
		code := 0
		out := "ok\n"
		if strings.Contains(cmd, "exit 3") {
			code, out = 3, "boom\n"
		}
		if strings.Contains(cmd, "npm test") {
			out = "12 passing\n"
		}
		return map[string]any{"output": out + exitMarker + fmt.Sprint(code) + "\n"}, nil
	case "spaces.proxy_list":
		var out []any
		for _, p := range f.proxies {
			if p["space_id"] == s("space") {
				out = append(out, p)
			}
		}
		return map[string]any{"proxies": out}, nil
	case "spaces.proxy_create":
		id := f.id("px")
		p := map[string]any{"id": id, "space_id": s("space"), "port": with["port"], "title": s("title"), "url": "/v1/proxy/" + id + "/"}
		f.proxies = append(f.proxies, p)
		return map[string]any{"proxy_id": id, "space_id": s("space"), "port": with["port"], "url": p["url"], "ok": true}, nil
	case "spaces.proxy_delete":
		f.deleted = append(f.deleted, "proxy:"+s("proxy"))
		return map[string]any{"ok": true}, nil
	case "developer.orgs_list":
		return map[string]any{"orgs": copyList(f.orgs)}, nil
	case "developer.org_create":
		id := f.id("org")
		org := map[string]any{"id": id, "name": s("name"), "role": "owner"}
		f.orgs = append(f.orgs, org)
		return map[string]any{"org": org}, nil
	case "developer.platform_get":
		if f.platform == nil {
			return map[string]any{"platform": nil}, nil
		}
		return map[string]any{"platform": f.platform}, nil
	case "developer.platform_create":
		f.platform = map[string]any{"id": f.id("pf"), "org": s("org"), "name": s("name"), "slug": s("slug")}
		return map[string]any{"platform": f.platform}, nil
	case "developer.platform_rename":
		f.platform["name"] = s("name")
		return map[string]any{"platform": f.platform}, nil
	case "developer.keys_list":
		return map[string]any{"keys": copyList(f.keys)}, nil
	case "developer.key_create":
		input := with["input"].(map[string]any)
		k := map[string]any{"id": f.id("key"), "name": input["name"], "status": "active", "permissions": input["permissions"], "limits": map[string]any{"rpm": 0.0, "models": []any{}}}
		f.keys = append(f.keys, k)
		return map[string]any{"key": k, "secret": "dk_live_supersecretvalue"}, nil
	case "developer.key_update":
		return map[string]any{"ok": true}, nil
	case "echo.it":
		return with, nil
	}
	return nil, &codedErr{"not_found", "no action " + action}
}

func copyList(in []map[string]any) []any {
	out := make([]any, len(in))
	for i, m := range in {
		cp := map[string]any{}
		for k, v := range m {
			cp[k] = v
		}
		out[i] = cp
	}
	return out
}

func codeOf(err error) string {
	var c *codedErr
	if errors.As(err, &c) {
		return c.code
	}
	return "internal"
}

func decode(t *testing.T, doc string) *Workflow {
	t.Helper()
	wf, err := Decode([]byte(doc))
	if err != nil {
		t.Fatal(err)
	}
	return wf
}

func run(t *testing.T, f *fakePlatform, doc string, mode string, inputs map[string]any, secrets map[string]string) *Report {
	t.Helper()
	return Run(context.Background(), decode(t, doc), f, nil, Options{Mode: mode, Inputs: inputs, Secrets: secrets, ErrorCode: codeOf,
		Sleep: func(context.Context, time.Duration) error { return nil }})
}

func step(rep *Report, path string) *StepRecord {
	for _, s := range rep.Steps {
		if s.Path == path {
			return s
		}
	}
	return nil
}

func dump(rep *Report) string {
	b, _ := json.MarshalIndent(rep, "", " ")
	return string(b)
}

// productWorkflow brings up a whole product: organization, platform, key,
// a space with agents and an app, the source of a full-stack app written to
// the computer, built, tested and served.
const productWorkflow = `{
  "aseman_workflow": "1",
  "name": "acme-shop",
  "version": "1.0.0",
  "inputs": {
    "product": {"type": "string", "default": "Acme Shop"},
    "agents": {"type": "list", "default": [
      {"name": "Builder", "model": "gpt-5-mini", "instructions": "You build."},
      {"name": "Advisor", "model": "gpt-5-mini", "instructions": "You advise."}
    ]}
  },
  "secrets": ["STRIPE_KEY"],
  "vars": {
    "slug": "${{ slug(inputs.product) }}",
    "app_dir": "apps/${{ vars.slug }}"
  },
  "assets": {
    "web/index.html": "<h1>Acme</h1>",
    "web/app.js": {"content": "console.log('${{ not rendered }}')"},
    "server/main.py": {"content": "print('hi')", "mode": "0755"},
    "config.tpl": {"content": "name=${{ inputs.product }}", "template": true}
  },
  "templates": {
    "agent_in_space": {
      "params": {"space": {"type": "string", "required": true}, "agent": {"type": "object", "required": true}},
      "steps": [
        {"id": "agent", "upsert": {"resource": "agent", "with": "${{ params.agent }}"}},
        {"id": "attach", "upsert": {"resource": "space_bot", "with": {"space": "${{ params.space }}", "bot": "${{ steps.agent.outputs.id }}"}}}
      ],
      "outputs": {"id": "${{ steps.agent.outputs.id }}", "name": "${{ params.agent.name }}"}
    }
  },
  "steps": [
    {"id": "org", "upsert": {"resource": "org", "with": {"name": "${{ inputs.product }} Inc"}}},
    {"id": "platform", "upsert": {"resource": "platform", "with": {"org": "${{ steps.org.outputs.id }}", "name": "${{ inputs.product }}", "slug": "${{ vars.slug }}"}}},
    {"id": "key", "sensitive": true, "upsert": {"resource": "key", "with": {"org": "${{ steps.org.outputs.id }}", "name": "server", "permissions": {"platform": "write", "chat": "write"}}}},
    {"id": "space", "upsert": {"resource": "space", "with": {"name": "${{ inputs.product }}", "description": "Where ${{ inputs.product }} is built"}}},
    {"id": "agents", "for_each": "${{ inputs.agents }}", "as": "agent", "use": "agent_in_space",
     "with": {"space": "${{ steps.space.outputs.id }}", "agent": "${{ agent }}"}},
    {"id": "install", "sandbox": {
      "space": "${{ steps.space.outputs.id }}", "start": true, "root": "${{ vars.app_dir }}", "clean": true,
      "assets": "server/", "files": {
        "README.md": "# ${{ inputs.product }}",
        "settings.json": {"json": {"agents": "${{ map(steps.agents.outputs, 'id') }}"}},
        "config.env": {"asset": "config.tpl"}
      },
      "render": true,
      "env": {"STRIPE_KEY": "${{ secrets.STRIPE_KEY }}"},
      "exec": ["pip install -r requirements.txt", {"run": "npm test", "expect": "passing"}],
      "proxy": {"port": 8000, "title": "${{ inputs.product }}", "start": "python server/main.py"}
    }},
    {"id": "web", "sandbox": {"space": "${{ steps.space.outputs.id }}", "root": "${{ vars.app_dir }}/public", "assets": "web/"}},
    {"id": "hello", "model": {"body": {"model": "openai/gpt-5-mini", "messages": [{"role": "user", "content": "Say hi to ${{ inputs.product }}"}]}}},
    {"assert": [{"that": "${{ len(steps.agents.outputs) == 2 }}", "message": "two agents"}]}
  ],
  "outputs": {
    "space": "${{ steps.space.outputs.id }}",
    "url": "${{ steps.install.outputs.proxy.url }}",
    "agents": "${{ map(steps.agents.outputs, a => a.name) }}",
    "key_secret": "${{ steps.key.outputs.result.secret }}"
  }
}`

func TestWorkflowBringsUpAProductAndIsIdempotent(t *testing.T) {
	f := newFake()
	f.running["sp4"] = 2 // the computer takes two polls to start
	rep := run(t, f, productWorkflow, ModeRun, nil, map[string]string{"STRIPE_KEY": "sk_test_123456"})
	if rep.Status != StatusSucceeded {
		t.Fatalf("run: %s %s\n%s", rep.Status, rep.Error, dump(rep))
	}
	if len(f.spaces) != 1 || len(f.bots) != 2 || len(f.members[f.spaces[0]["id"].(string)]) != 2 || f.platform == nil || len(f.keys) != 1 {
		t.Fatalf("state: spaces=%v bots=%v members=%v platform=%v keys=%v", f.spaces, f.bots, f.members, f.platform, f.keys)
	}
	space := f.spaces[0]["id"].(string)
	root := "/workspace/apps/acme-shop"
	if f.files[space+":"+root+"/README.md"] != "# Acme Shop" {
		t.Fatalf("README rendered: %q", f.files[space+":"+root+"/README.md"])
	}
	if got := f.files[space+":"+root+"/config.env"]; got != "name=Acme Shop" {
		t.Fatalf("a template asset is rendered: %q", got)
	}
	if got := f.files[space+":"+root+"/settings.json"]; !strings.Contains(got, `"agents"`) || !strings.Contains(got, "bot") {
		t.Fatalf("json file: %q", got)
	}
	if got := f.files[space+":"+root+"/public/app.js"]; !strings.HasPrefix(got, "b64:") {
		t.Fatalf("assets are copied as they are, not rendered: %q", got)
	}
	if got := f.files[space+":"+root+"/main.py"]; got == "" {
		t.Fatalf("assets under the prefix are written without it: %v", f.files)
	}
	if _, ok := f.files[space+":"+root+"/web/index.html"]; ok {
		t.Fatalf("only the assets under the prefix: %v", f.files)
	}
	if len(f.commands) < 3 || !strings.Contains(f.commands[0], "chmod 0755") || !strings.Contains(f.commands[1], "export STRIPE_KEY='sk_test_123456'") || !strings.Contains(f.commands[1], "cd '/workspace/apps/acme-shop'") {
		t.Fatalf("commands: %q", f.commands)
	}
	if rep.Outputs["url"] != "/v1/proxy/px7/" || fmt.Sprint(rep.Outputs["agents"]) != "[Builder Advisor]" {
		t.Fatalf("outputs: %v", rep.Outputs)
	}
	// Secrets never reach the stored record.
	if text := dump(rep); strings.Contains(text, "sk_test_123456") || strings.Contains(text, "dk_live_supersecretvalue") {
		t.Fatalf("a secret leaked into the report:\n%s", text)
	}
	if rep.Counts.Created < 7 {
		t.Fatalf("counts: %+v", rep.Counts)
	}
	if len(f.models) != 1 || !strings.Contains(fmt.Sprint(f.models[0]["messages"]), "Say hi to Acme Shop") {
		t.Fatalf("model: %v", f.models)
	}

	// A second run changes nothing it does not need to.
	before := len(f.spaces) + len(f.bots) + len(f.keys) + len(f.proxies)
	rep2 := run(t, f, productWorkflow, ModeRun, nil, map[string]string{"STRIPE_KEY": "sk_test_123456"})
	if rep2.Status != StatusSucceeded {
		t.Fatalf("rerun: %s %s", rep2.Status, rep2.Error)
	}
	if after := len(f.spaces) + len(f.bots) + len(f.keys) + len(f.proxies); after != before {
		t.Fatalf("a rerun must not duplicate resources: %d → %d", before, after)
	}
	if op := step(rep2, "space").Operation; op != "unchanged" {
		t.Fatalf("space on rerun: %s", op)
	}
	if op := step(rep2, "platform").Operation; op != "unchanged" {
		t.Fatalf("platform on rerun: %s", op)
	}

	// Changing an input updates what it describes, in place.
	rep3 := run(t, f, strings.Replace(productWorkflow, `"Where ${{ inputs.product }} is built"`, `"A new description"`, 1), ModeRun, nil, map[string]string{"STRIPE_KEY": "x"})
	if rep3.Status != StatusSucceeded || step(rep3, "space").Operation != "updated" || f.spaces[0]["description"] != "A new description" {
		t.Fatalf("update: %s %s %v", rep3.Status, step(rep3, "space").Operation, f.spaces[0])
	}
}

func TestPlanShowsWhatARunWouldDoWithoutChangingAnything(t *testing.T) {
	f := newFake()
	rep := run(t, f, productWorkflow, ModePlan, nil, nil)
	if rep.Status != StatusPlanned {
		t.Fatalf("plan: %s %s\n%s", rep.Status, rep.Error, dump(rep))
	}
	for _, c := range f.calls {
		if !strings.HasSuffix(c, "_list") && !strings.HasSuffix(c, "_get") {
			t.Fatalf("a plan only reads: %v", f.calls)
		}
	}
	if op := step(rep, "space").Operation; op != "would_create" {
		t.Fatalf("space: %s", op)
	}
	if op := step(rep, "platform").Operation; op != "create_or_update" {
		t.Fatalf("platform depends on an org that does not exist yet: %s", op)
	}
	inst := step(rep, "install")
	if inst == nil || !strings.Contains(fmt.Sprint(inst.Request), "README.md") {
		t.Fatalf("install plan: %+v", inst)
	}
}

func TestValidationFindsMistakesBeforeAnythingRuns(t *testing.T) {
	doc := `{
	  "aseman_workflow": "1", "name": "bad",
	  "steps": [
	    {"id": "a", "action": "spaces.space_create", "upsert": {"resource": "space", "with": {"name": "x"}}},
	    {"id": "a", "action": "nodots"},
	    {"id": "b", "log": "${{ steps.missing.outputs }}"},
	    {"id": "c", "log": "${{ 1 + }}"},
	    {"id": "d", "upsert": {"resource": "planet", "with": {}}},
	    {"id": "e", "use": "nope"},
	    {"id": "f", "retry": {"attempts": 99}, "log": "x"},
	    {"id": "g", "action": "admin.health"}
	  ]
	}`
	wf := decode(t, doc)
	issues := Validate(wf, catalogFunc(func(name string) (bool, string) {
		if strings.HasPrefix(name, "admin.") {
			return false, "node administration is not on this door"
		}
		return true, ""
	}))
	text := fmt.Sprint(issues)
	for _, want := range []string{"one kind", "already used", "namespace.action", "steps.missing", "unexpected end", "unknown resource", "no template", "attempts", "node administration"} {
		if !strings.Contains(text, want) {
			t.Errorf("missing issue %q in %s", want, text)
		}
	}
	if _, err := Decode([]byte(`{"aseman_workflow":"1","name":"x","steps":[{"action":"a.b","whith":{}}]}`)); err == nil {
		t.Fatal("a misspelt field must be refused")
	}
	f := newFake()
	rep := Run(context.Background(), wf, f, nil, Options{})
	if rep.Status != StatusFailed || rep.ErrorCode != "invalid_workflow" || len(f.calls) != 0 {
		t.Fatalf("an invalid workflow runs nothing: %s %s %v", rep.Status, rep.ErrorCode, f.calls)
	}
}

type catalogFunc func(string) (bool, string)

func (c catalogFunc) ActionExists(name string) (bool, string) { return c(name) }

func TestInputsAreCheckedAndDefaulted(t *testing.T) {
	doc := `{"aseman_workflow":"1","name":"in","inputs":{
	  "count":{"type":"integer","min":1,"max":5,"required":true},
	  "tier":{"type":"string","enum":["free","pro"],"default":"free"}},
	  "steps":[{"id":"x","action":"echo.it","with":{"n":"${{ inputs.count * 2 }}","tier":"${{ inputs.tier }}"}}],
	  "outputs":{"n":"${{ steps.x.outputs.n }}"}}`
	f := newFake()
	if rep := run(t, f, doc, ModeRun, map[string]any{"count": 9.0}, nil); rep.Status != StatusFailed || !strings.Contains(rep.Error, "at most 5") {
		t.Fatalf("out of range: %s %s", rep.Status, rep.Error)
	}
	if rep := run(t, f, doc, ModeRun, nil, nil); rep.Status != StatusFailed || !strings.Contains(rep.Error, "required") {
		t.Fatalf("required: %s %s", rep.Status, rep.Error)
	}
	rep := run(t, f, doc, ModeRun, map[string]any{"count": "3"}, nil)
	if rep.Status != StatusSucceeded || rep.Outputs["n"] != 6.0 {
		t.Fatalf("typed: %s %s %v", rep.Status, rep.Error, rep.Outputs)
	}
}

func TestRetriesAndContinueOnErrorAndOnError(t *testing.T) {
	f := newFake()
	f.fail["echo.it"] = 2
	doc := `{"aseman_workflow":"1","name":"r","steps":[
	  {"id":"flaky","action":"echo.it","with":{"v":1},"retry":{"attempts":3,"delay":"1s","backoff":2}},
	  {"id":"broken","action":"nope.nope","continue_on_error":true,"on_error":[{"set":{"why":"${{ error.code }}"}}]},
	  {"id":"after","log":"why=${{ vars.why }} status=${{ steps.broken.status }}"}
	]}`
	rep := run(t, f, doc, ModeRun, nil, nil)
	if rep.Status != StatusSucceeded {
		t.Fatalf("%s %s\n%s", rep.Status, rep.Error, dump(rep))
	}
	if a := step(rep, "flaky").Attempts; a != 3 {
		t.Fatalf("attempts: %d", a)
	}
	if out := step(rep, "after").Outputs; out != "why=not_found status=failed" {
		t.Fatalf("after: %v", out)
	}
	// A refusal is not retried.
	f.fail["echo.it"] = 5
	f.failErr = &codedErr{"permission", "no"}
	rep = run(t, f, `{"aseman_workflow":"1","name":"p","steps":[{"id":"x","action":"echo.it","retry":{"attempts":4}}]}`, ModeRun, nil, nil)
	if rep.Status != StatusFailed || step(rep, "x").Attempts != 1 || rep.ErrorCode != "permission" {
		t.Fatalf("permission: %s %d %s", rep.Status, step(rep, "x").Attempts, rep.ErrorCode)
	}
}

func TestRollbackUndoesWhatTheRunMade(t *testing.T) {
	f := newFake()
	doc := `{"aseman_workflow":"1","name":"rb","options":{"rollback_on_failure":true},"steps":[
	  {"id":"space","upsert":{"resource":"space","with":{"name":"Temp"}}},
	  {"id":"bot","upsert":{"resource":"agent","with":{"name":"Temp agent"}}},
	  {"id":"note","action":"echo.it","compensate":{"log":"undo note ${{ result.v }}"},"with":{"v":"n1"}},
	  {"id":"boom","fail":"stop here"}
	],"finally":[{"log":"ended ${{ outcome.status }}"}]}`
	rep := run(t, f, doc, ModeRun, nil, nil)
	if rep.Status != StatusRolledBack || rep.Error != "stop here" {
		t.Fatalf("%s %s", rep.Status, rep.Error)
	}
	if fmt.Sprint(f.deleted) != "[bot:bot2 space:sp1]" {
		t.Fatalf("newest first: %v", f.deleted)
	}
	if len(rep.Rollback) != 3 {
		t.Fatalf("rollback: %+v", rep.Rollback)
	}
	last := rep.Events[len(rep.Events)-2]
	if !strings.Contains(last.Message, "ended rolled_back") {
		t.Fatalf("finally sees the outcome: %+v", rep.Events)
	}
}

func TestLoopsRunConcurrentlyAndCollect(t *testing.T) {
	f := newFake()
	doc := `{"aseman_workflow":"1","name":"loop","steps":[
	  {"id":"made","for_each":"${{ range(6) }}","concurrency":4,"action":"echo.it","with":{"n":"${{ item * 10 }}"},"collect":"${{ result.n }}"},
	  {"id":"pairs","for_each":{"a":1,"b":2},"as":"kv","log":"${{ kv.key }}=${{ kv.value }}"},
	  {"id":"nested","for_each":["x","y"],"steps":[
	     {"id":"inner","action":"echo.it","with":{"v":"${{ item }}${{ index }}"}},
	     {"id":"twice","action":"echo.it","with":{"v":"${{ steps.inner.outputs.v }}!"}}
	  ]}
	],"outputs":{"made":"${{ sum(steps.made.outputs) }}","nested":"${{ map(steps.nested.outputs, o => o.v) }}","pairs":"${{ steps.pairs.outputs }}"}}`
	rep := run(t, f, doc, ModeRun, nil, nil)
	if rep.Status != StatusSucceeded {
		t.Fatalf("%s %s", rep.Status, rep.Error)
	}
	if rep.Outputs["made"] != 150.0 || fmt.Sprint(rep.Outputs["nested"]) != "[x0! y1!]" || fmt.Sprint(rep.Outputs["pairs"]) != "[a=1 b=2]" {
		t.Fatalf("outputs: %v", rep.Outputs)
	}
}

func TestWaitPollsUntilTheConditionHolds(t *testing.T) {
	f := newFake()
	f.running["s1"] = 3
	doc := `{"aseman_workflow":"1","name":"w","steps":[
	  {"id":"up","wait":{"action":"spaces.sandbox_status","with":{"space":"s1"},"until":"result.status == 'running'","interval":"2s","timeout":"1m"}},
	  {"id":"never","wait":{"action":"spaces.sandbox_status","with":{"space":"s1"},"until":"result.status == 'gone'","interval":"10s","timeout":"20s"}}
	]}`
	clock := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	var mu sync.Mutex
	rep := Run(context.Background(), decode(t, doc), f, nil, Options{ErrorCode: codeOf,
		Now: func() time.Time { mu.Lock(); defer mu.Unlock(); return clock },
		Sleep: func(_ context.Context, d time.Duration) error {
			mu.Lock()
			clock = clock.Add(d)
			mu.Unlock()
			return nil
		}})
	if step(rep, "up").Status != StatusSucceeded {
		t.Fatalf("up: %+v", step(rep, "up"))
	}
	if rep.Status != StatusFailed || rep.ErrorCode != "timeout" {
		t.Fatalf("never: %s %s", rep.Status, rep.ErrorCode)
	}
}

func TestSandboxCommandFailureStopsTheRun(t *testing.T) {
	f := newFake()
	doc := `{"aseman_workflow":"1","name":"s","steps":[
	  {"id":"build","sandbox":{"space":"s1","exec":["echo fine","exit 3","echo never"]}}
	]}`
	rep := run(t, f, doc, ModeRun, nil, nil)
	if rep.Status != StatusFailed || !strings.Contains(rep.Error, "exited 3") || len(f.commands) != 2 {
		t.Fatalf("%s %s %v", rep.Status, rep.Error, f.commands)
	}
}

func TestResumeReusesFinishedSteps(t *testing.T) {
	f := newFake()
	doc := `{"aseman_workflow":"1","name":"res","steps":[
	  {"id":"one","action":"echo.it","with":{"v":"fresh"}},
	  {"id":"two","action":"echo.it","with":{"v":"${{ steps.one.outputs.v }}-2"}}
	],"outputs":{"two":"${{ steps.two.outputs.v }}"}}`
	rep := Run(context.Background(), decode(t, doc), f, nil, Options{ErrorCode: codeOf, Resume: map[string]any{"one": map[string]any{"v": "old"}}})
	if rep.Status != StatusSucceeded || rep.Outputs["two"] != "old-2" || step(rep, "one").Status != StatusReused || len(f.calls) != 1 {
		t.Fatalf("%s %v %v", rep.Status, rep.Outputs, f.calls)
	}
}

func TestParallelGroupsAndDefaults(t *testing.T) {
	f := newFake()
	doc := `{"aseman_workflow":"1","name":"par",
	  "defaults":{"with":{"echo":{"org":"o1"}}},
	  "steps":[{"id":"g","parallel":true,"steps":[
	    {"id":"a","action":"echo.it","with":{"v":"a"}},
	    {"id":"b","action":"echo.it","with":{"v":"b","org":"mine"}}
	  ]}],
	  "outputs":{"a":"${{ steps.a.outputs }}","b":"${{ steps.b.outputs.org }}"}}`
	rep := run(t, f, doc, ModeRun, nil, nil)
	if rep.Status != StatusSucceeded || fmt.Sprint(rep.Outputs["a"]) != "map[org:o1 v:a]" || rep.Outputs["b"] != "mine" {
		t.Fatalf("%s %s %v", rep.Status, rep.Error, rep.Outputs)
	}
}

func TestExpressions(t *testing.T) {
	env := &staticEnv{vars: map[string]any{
		"inputs": map[string]any{"name": "Acme Shop", "n": 3.0, "tags": []any{"a", "b"}},
		"list":   []any{map[string]any{"id": "1", "kind": "agent"}, map[string]any{"id": "2", "kind": "tool"}},
	}}
	cases := map[string]any{
		"inputs.name":                                      "Acme Shop",
		"slug(inputs.name)":                                "acme-shop",
		"inputs.n * 2 + 1":                                 7.0,
		"inputs.missing.deeper ?? 'dflt'":                  "dflt",
		"'b' in inputs.tags":                               true,
		"inputs.n > 2 && inputs.n < 5 ? 'mid' : 'out'":     "mid",
		"find(list, x => x.kind == 'tool').id":             "2",
		"map(filter(list, 'kind', 'agent'), 'id')[0]":      "1",
		"len(inputs.tags) == 2":                            true,
		"format('{0}-{1}', inputs.name, inputs.n)":         "Acme Shop-3",
		"join(sort(['c','a','b']), ',')":                   "a,b,c",
		"merge({}.x ?? object('a', 1), object('b', 2))":    nil, // {} is not a literal; see below
		"not empty(inputs.tags)":                           true,
		"inputs.tags[-1]":                                  "b",
		"default('', 'fallback')":                          "fallback",
		"sort_by(list, x => x.id, true)[0].id":             "2",
		"key_by(list, 'id')['2'].kind":                     "tool",
		"regex_find('v1.2.3', '(\\\\d+)\\\\.(\\\\d+)')[2]": "2",
		"int('42') + 1":                                    43.0,
		"(1 + 2) * 3":                                      9.0,
		"!true || false":                                   false,
		"upper(substr(inputs.name, 0, 4))":                 "ACME",
	}
	for src, want := range cases {
		if strings.Contains(src, "{}") {
			if _, err := Parse(src); err == nil {
				t.Errorf("%s: object literals are written with object()", src)
			}
			continue
		}
		e, err := Parse(src)
		if err != nil {
			t.Errorf("%s: %v", src, err)
			continue
		}
		got, err := e.Eval(env)
		if err != nil {
			t.Errorf("%s: %v", src, err)
			continue
		}
		if !Equal(got, want) {
			t.Errorf("%s = %#v, want %#v", src, got, want)
		}
	}
	got, err := RenderString("Hi ${{ inputs.name }} (${{ inputs.n }}) $${{ literal }}", env)
	if err != nil || got != "Hi Acme Shop (3) ${{ literal }}" {
		t.Fatalf("render: %v %v", got, err)
	}
	typed, _ := RenderString("${{ inputs.tags }}", env)
	if l, ok := typed.([]any); !ok || len(l) != 2 {
		t.Fatalf("a lone expression keeps its type: %#v", typed)
	}
	raw, _ := Render(map[string]any{"$raw": "${{ untouched }}"}, env)
	if raw != "${{ untouched }}" {
		t.Fatalf("raw: %v", raw)
	}
}

type staticEnv struct{ vars map[string]any }

func (s *staticEnv) Lookup(n string) (any, bool) { v, ok := s.vars[n]; return v, ok }
func (s *staticEnv) Func(n string) (Func, bool)  { b, ok := builtins[n]; return b.fn, ok }

// The documented example stays a valid workflow.
func TestDocumentedExampleIsValid(t *testing.T) {
	raw, err := os.ReadFile("../../../../../docs/workflows/fullstack-product.json")
	if err != nil {
		t.Fatal(err)
	}
	wf, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	if issues := Validate(wf, nil); len(issues) > 0 {
		t.Fatalf("issues: %+v", issues)
	}
	rep := Run(context.Background(), wf, newFake(), nil, Options{Mode: ModePlan, ErrorCode: codeOf, Inputs: map[string]any{"team": []any{"bob"}}})
	if rep.Status != StatusPlanned {
		t.Fatalf("plan: %s %s\n%s", rep.Status, rep.Error, dump(rep))
	}
}
