package tools

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"strings"
	"sync"
	"testing"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

type fakeAction struct {
	name   string
	handle func(body map[string]any) (any, error)
}

func (a fakeAction) Meta() api.ActionMeta { return api.ActionMeta{Namespace: "spaces", Name: a.name} }
func (a fakeAction) Handle(_ context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var body map[string]any
	_ = json.Unmarshal(req.Body, &body)
	out, err := a.handle(body)
	if err != nil {
		return nil, err
	}
	return helper.JSON(out)
}

// fakeSpace serves the platform actions Code Mode's sandbox and agent paths use.
type fakeSpace struct {
	mu       sync.Mutex
	commands []string
	stored   map[string]string
	sent     []map[string]any
}

func codeModeTestService(t *testing.T) (*Service, *fakeSpace, context.Context) {
	t.Helper()
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global()})
	f := &fakeSpace{stored: map[string]string{"apps/x/README.md": "hello"}}
	register := func(name string, handle func(map[string]any) (any, error)) {
		if err := k.Actions().Register("spaces", fakeAction{name: name, handle: handle}); err != nil {
			t.Fatal(err)
		}
	}
	register("ask", func(b map[string]any) (any, error) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.commands = append(f.commands, b["body"].(string))
		return map[string]any{"exit_code": 0, "output": "ok\n"}, nil
	})
	register("sandbox_files", func(b map[string]any) (any, error) {
		f.mu.Lock()
		defer f.mu.Unlock()
		p := b["path"].(string)
		switch b["operation"] {
		case "read":
			if c, ok := f.stored[p]; ok {
				return map[string]any{"content": c}, nil
			}
			return map[string]any{"ok": false, "missing": true}, nil
		case "write":
			data, _ := base64.StdEncoding.DecodeString(b["data_base64"].(string))
			f.stored[p] = string(data)
		}
		return map[string]any{"ok": true}, nil
	})
	register("bots_list", func(map[string]any) (any, error) {
		return map[string]any{"bots": []map[string]any{
			{"id": "b-lead", "account_id": "a-lead", "name": "aseman", "kind": "agent", "vm_type": "deepagents", "vm_id": codeModeLeadVM},
			{"id": "b-res", "account_id": "a-res", "name": "Researcher", "kind": "agent", "vm_type": "deepagents"},
			{"id": "b-wx", "account_id": "a-wx", "name": "Weather", "kind": "tool", "vm_type": "mcp"},
		}}, nil
	})
	register("message_send", func(b map[string]any) (any, error) {
		f.mu.Lock()
		f.sent = append(f.sent, b)
		f.mu.Unlock()
		return map[string]any{"replies": []map[string]any{{"bot_id": "b-res", "reply": "three findings"}}}, nil
	})
	actor, _ := identity.New(1)
	ctx := vmm.WithExecution(helper.WithActor(context.Background(), actor), vmm.Execution{SpaceID: "space-1", RoomID: "room-1"})
	return &Service{K: k}, f, ctx
}

func TestCodeModeSandboxWritesManyFilesInOneCommand(t *testing.T) {
	s, f, ctx := codeModeTestService(t)
	out, err := s.CodeModeRequestCall(ctx, "space-1", CodeModeRequest{Path: "/sandbox/write_files", Body: map[string]any{
		"dir": "/workspace/apps/x",
		"files": []any{
			map[string]any{"path": "server.js", "content": "console.log(1)"},
			map[string]any{"path": "test/a.test.js", "content": "it()"},
			map[string]any{"path": "/workspace/apps/x/READY.json", "content": "{}"},
		},
	}})
	if err != nil {
		t.Fatal(err)
	}
	written, _ := out.(map[string]any)["written"].([]string)
	if len(written) != 3 || written[1] != "/workspace/apps/x/test/a.test.js" {
		t.Fatalf("written = %#v", out)
	}
	if len(f.commands) != 1 || !strings.HasPrefix(f.commands[0], "python3 -c ") {
		t.Fatalf("commands = %v", f.commands)
	}
	arg := f.commands[0][strings.LastIndex(f.commands[0], " ")+1:]
	raw, _ := base64.StdEncoding.DecodeString(arg)
	var files []codeModeFile
	if err := json.Unmarshal(raw, &files); err != nil || len(files) != 3 {
		t.Fatalf("payload = %s (%v)", raw, err)
	}

	// A large file goes on its own, through the provider.
	big := strings.Repeat("x", codeModeWriteChunk)
	if _, err := s.CodeModeRequestCall(ctx, "space-1", CodeModeRequest{Path: "/sandbox/write_files", Body: map[string]any{
		"files": []any{map[string]any{"path": "apps/x/big.txt", "content": big}},
	}}); err != nil {
		t.Fatal(err)
	}
	if f.stored["apps/x/big.txt"] != big || len(f.commands) != 1 {
		t.Fatalf("big file not stored directly (commands %d)", len(f.commands))
	}

	if _, err := s.CodeModeRequestCall(ctx, "space-1", CodeModeRequest{Path: "/sandbox/write_files", Body: map[string]any{
		"files": []any{map[string]any{"path": "/etc/passwd", "content": "x"}},
	}}); err == nil {
		t.Fatal("a path outside /workspace must be refused")
	}
}

func TestCodeModeSandboxExecReadAndEdit(t *testing.T) {
	s, f, ctx := codeModeTestService(t)
	out, err := s.CodeModeRequestCall(ctx, "space-1", CodeModeRequest{Path: "/sandbox/exec", Body: map[string]any{
		"command": "npm test", "cwd": "/workspace/apps/x",
	}})
	if err != nil {
		t.Fatal(err)
	}
	if res := out.(map[string]any); res["exit_code"] != 0 || res["output"] != "ok\n" {
		t.Fatalf("exec = %#v", out)
	}
	if f.commands[0] != "cd '/workspace/apps/x' && npm test" {
		t.Fatalf("command = %q", f.commands[0])
	}
	out, err = s.CodeModeRequestCall(ctx, "space-1", CodeModeRequest{Path: "/sandbox/read_files", Body: map[string]any{
		"dir": "apps/x", "paths": []any{"README.md", "missing.txt"},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if m := out.(map[string]any); m["README.md"] != "hello" || m["missing.txt"] != nil {
		t.Fatalf("read = %#v", out)
	}
	if _, err := s.CodeModeRequestCall(ctx, "space-1", CodeModeRequest{Path: "/sandbox/edit_file", Body: map[string]any{
		"path": "/workspace/apps/x/README.md", "old": "hello", "new": "hello world",
	}}); err != nil {
		t.Fatal(err)
	}
	if f.stored["apps/x/README.md"] != "hello world" {
		t.Fatalf("edit = %q", f.stored["apps/x/README.md"])
	}
}

func TestCodeModeAgentsAreSubagents(t *testing.T) {
	s, f, ctx := codeModeTestService(t)
	agents, err := s.codeModeAgents(ctx, "space-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(agents) != 1 || agents[0].Slug != "researcher" {
		t.Fatalf("agents = %#v (the lead and apps are not subagents)", agents)
	}
	// Called from inside an execute, in the middle of other calls.
	out, err := runCodeModeJS(`() => {
  const r = codemode.request({ path: "/agents/researcher", body: { task: "find three things" } });
  codemode.request({ path: "/sandbox/write_files", body: { files: [{ path: "notes.md", content: r.answer }] } });
  return r;
}`, map[string]any{}, func(opts CodeModeRequest) (any, error) { return s.CodeModeRequestCall(ctx, "space-1", opts) })
	if err != nil {
		t.Fatal(err)
	}
	if m := out.(map[string]any); m["answer"] != "three findings" || m["agent"] != "Researcher" {
		t.Fatalf("answer = %#v", out)
	}
	if f.stored["notes.md"] != "three findings" {
		t.Fatalf("the answer did not reach the next call: %v", f.stored)
	}
	sent := f.sent[0]
	body, _ := sent["body"].(string)
	if !strings.HasPrefix(body, "@Researcher [task ") || !strings.HasSuffix(body, "] find three things") ||
		sent["wait"] != true || sent["room"] != "room-1" {
		t.Fatalf("hand-off = %#v", sent)
	}
	if tag := codeModeTaskTag(); len(tag) != 10 || strings.Trim(tag, "0123456789abcdef") != "" {
		t.Fatalf("task tag %q does not match team.TASK_TAG", tag)
	}
	if _, err := s.CodeModeRequestCall(ctx, "space-1", CodeModeRequest{Path: "/agents/aseman", Body: map[string]any{"task": "x"}}); err == nil {
		t.Fatal("nobody delegates up to the lead")
	}
}
