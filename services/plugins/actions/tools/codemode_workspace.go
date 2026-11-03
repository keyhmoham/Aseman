package tools

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"path"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// One-shot work in Code Mode: the space's shared computer and its agents are
// part of the capability surface, so a single execute can do a whole job —
// lay out a project, write every file, run its tests, validate and publish
// it, and hand a part to another agent in the middle — instead of one model
// step per file, command or hand-off.
//
//	POST /sandbox/exec         {command, cwd?}                 → {exit_code, output}
//	POST /sandbox/write_files  {files: [{path, content|data_base64}], dir?} → {written}
//	POST /sandbox/read_files   {paths, dir?}                   → {path: content | null}
//	POST /sandbox/edit_file    {path, old, new, replace_all?}  → {replaced}
//	POST /sandbox/list         {path}                          → {items}
//	POST /sandbox/delete       {path}                          → {ok}
//	POST /agents/{name}        {task}                          → {agent, answer}
//
// Sandbox calls go through spaces.ask (the sandbox bot) and
// spaces.sandbox_files, agent calls through spaces.message_send with wait —
// the same actions, billing, limits and room visibility as the native tools.

const codeModeWorkspace = "/workspace"

// Files written in one command, by their encoded size (a shell argument stays
// well under the kernel's per-argument limit). Larger files go one by one.
const codeModeWriteChunk = 48 << 10

// The space's built-in lead (nobody delegates up to it; see subagents.py).
const codeModeLeadVM = "harness-aseman"

// codeModeLegacyLeadVM is the lead's id before it moved to the harness.
const codeModeLegacyLeadVM = "deepagents-aseman"

var codeModeSandboxOps = []struct {
	name, summary string
	schema        map[string]any
}{
	{"exec", "Run a shell command on the space's shared computer (bash, under /workspace). Returns {exit_code, output}; a failing command is an outcome, not an error. Chain steps with && or a script to do a whole job in one call.",
		codeModeObject(map[string]any{
			"command": map[string]any{"type": "string", "description": "Shell command"},
			"cwd":     map[string]any{"type": "string", "description": "Directory to run in (default /workspace)"},
		}, "command")},
	{"write_files", "Write many files at once (folders are created). Paths are absolute under /workspace or relative to dir. Returns {written: [paths]}.",
		codeModeObject(map[string]any{
			"dir": map[string]any{"type": "string", "description": "Base folder for relative paths (default /workspace)"},
			"files": map[string]any{"type": "array", "items": codeModeObject(map[string]any{
				"path":        map[string]any{"type": "string"},
				"content":     map[string]any{"type": "string", "description": "Text content"},
				"data_base64": map[string]any{"type": "string", "description": "Binary content, base64"},
			}, "path")},
		}, "files")},
	{"read_files", "Read many files at once. Returns {path: content}; a missing file is null.",
		codeModeObject(map[string]any{
			"dir":   map[string]any{"type": "string", "description": "Base folder for relative paths (default /workspace)"},
			"paths": map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
		}, "paths")},
	{"edit_file", "Replace text in a file. old must occur exactly once unless replace_all. Returns {replaced}.",
		codeModeObject(map[string]any{
			"path":        map[string]any{"type": "string"},
			"old":         map[string]any{"type": "string"},
			"new":         map[string]any{"type": "string"},
			"replace_all": map[string]any{"type": "boolean"},
		}, "path", "old", "new")},
	{"list", "List a folder. Returns {items: [{name, type, size}]}.",
		codeModeObject(map[string]any{"path": map[string]any{"type": "string"}}, "path")},
	{"delete", "Delete a file or folder under /workspace.",
		codeModeObject(map[string]any{"path": map[string]any{"type": "string"}}, "path")},
}

func codeModeObject(props map[string]any, required ...string) map[string]any {
	out := map[string]any{"type": "object", "properties": props}
	if len(required) > 0 {
		out["required"] = required
	}
	return out
}

func codeModePost(operationID, summary, description string, tags []string, schema map[string]any, extra map[string]any) map[string]any {
	op := map[string]any{
		"operationId": operationID,
		"summary":     summary,
		"description": description,
		"tags":        tags,
		"requestBody": map[string]any{
			"required": true,
			"content":  map[string]any{"application/json": map[string]any{"schema": schema}},
		},
		"responses": map[string]any{"200": map[string]any{"description": summary}},
	}
	for k, v := range extra {
		op[k] = v
	}
	return map[string]any{"post": op}
}

// codeModeAddSandboxPaths adds /sandbox/* unless the request has no sandbox.
func codeModeAddSandboxPaths(ctx context.Context, paths map[string]any) bool {
	if vmm.ExecutionFrom(ctx).NoSandbox {
		return false
	}
	for _, op := range codeModeSandboxOps {
		paths["/sandbox/"+op.name] = codeModePost("sandbox__"+op.name, op.summary, op.summary,
			[]string{"sandbox", op.name}, op.schema, nil)
	}
	return true
}

type codeModeAgent struct {
	Slug        string
	BotID       string
	AccountID   string
	Name        string
	Description string
}

// codeModeAgents are the space's agents another agent can hand a task to:
// runtime agents other than the caller and the lead.
func (s *Service) codeModeAgents(ctx context.Context, spaceID string) ([]codeModeAgent, error) {
	raw, err := s.codeModeDispatch(ctx, "spaces", "bots_list", map[string]any{"space": spaceID})
	if err != nil {
		return nil, err
	}
	var listed struct {
		Bots []struct {
			ID          string `json:"id"`
			AccountID   string `json:"account_id"`
			Name        string `json:"name"`
			Kind        string `json:"kind"`
			VMType      string `json:"vm_type"`
			VMID        string `json:"vm_id"`
			Description string `json:"description"`
		} `json:"bots"`
	}
	if err := json.Unmarshal(raw, &listed); err != nil {
		return nil, err
	}
	self := vmm.ExecutionFrom(ctx).AgentID
	used := map[string]bool{}
	var out []codeModeAgent
	for _, b := range listed.Bots {
		if b.Kind != "agent" || b.ID == self || b.VMID == codeModeLeadVM || b.VMID == codeModeLegacyLeadVM {
			continue
		}
		switch b.VMType {
		case "harness", "deepagents", "opencode", "deepseek", "langchain", "grok", "":
		default:
			continue
		}
		slug := strings.Trim(codeModeSlug.ReplaceAllString(strings.ToLower(b.Name), "_"), "_")
		if slug == "" {
			slug = "agent"
		}
		base := slug
		for i := 2; used[slug]; i++ {
			slug = fmt.Sprintf("%s_%d", base, i)
		}
		used[slug] = true
		out = append(out, codeModeAgent{Slug: slug, BotID: b.ID, AccountID: b.AccountID, Name: b.Name, Description: b.Description})
	}
	return out, nil
}

func codeModeAddAgentPaths(paths map[string]any, agents []codeModeAgent) {
	schema := codeModeObject(map[string]any{
		"task": map[string]any{"type": "string", "description": "The complete task: goal, inputs, expected result and where to put it"},
	}, "task")
	for _, a := range agents {
		desc := a.Description
		if desc == "" {
			desc = "The space's " + a.Name + " agent."
		}
		paths["/agents/"+a.Slug] = codeModePost("agents__"+a.Slug, "Hand a task to "+a.Name+" and get its answer",
			"["+a.Name+"] "+desc+"\nRuns the agent's own turn (in the room, on the shared computer) and returns {agent, answer}. "+
				"Use codemode.batch to run several agents at once.",
			[]string{"agents", a.Slug}, schema, map[string]any{"x-aseman-bot": a.BotID})
	}
}

// codeModeCaller is the account Code Mode acts as: the turn's agent, else the
// signed-in person (external MCP hosts).
func (s *Service) codeModeCaller(ctx context.Context) (api.Caller, error) {
	if id := vmm.ExecutionFrom(ctx).AgentID; id != "" {
		if rec, err := s.bot(ctx, id); err == nil && !rec.AccountID.IsZero() {
			return api.Caller{ID: rec.AccountID, Kind: "bot"}, nil
		}
	}
	if actor := helper.Actor(ctx); !actor.IsZero() {
		return api.Caller{ID: actor, Kind: "user"}, nil
	}
	return api.Caller{}, errs.Unauthenticated("Code Mode has no caller")
}

func (s *Service) codeModeDispatch(ctx context.Context, namespace, action string, body map[string]any) (json.RawMessage, error) {
	caller, err := s.codeModeCaller(ctx)
	if err != nil {
		return nil, err
	}
	b, err := json.Marshal(body)
	if err != nil {
		return nil, errs.InvalidArgument("body must be a JSON object")
	}
	resp, err := s.K.Actions().Dispatch(ctx, namespace, action, &api.ActionRequest{Caller: caller, Body: b})
	if err != nil {
		return nil, err
	}
	return resp.Body, nil
}

func codeModeRoom(ctx context.Context) string {
	if room := vmm.ExecutionFrom(ctx).RoomID; room != "" {
		return room
	}
	return vmm.RoomFrom(ctx)
}

// codeModeFilePath resolves p (absolute under /workspace, or relative to dir)
// to a /workspace path, refusing what the request may not touch.
func codeModeFilePath(ctx context.Context, dir, p string) (string, error) {
	p = strings.TrimSpace(p)
	if p == "" {
		return "", errs.InvalidArgument("path is required")
	}
	if !strings.HasPrefix(p, "/") {
		base := strings.TrimSpace(dir)
		if base == "" {
			base = codeModeWorkspace
		} else if !strings.HasPrefix(base, "/") {
			base = codeModeWorkspace + "/" + base
		}
		p = base + "/" + p
	}
	clean := path.Clean(p)
	if clean != codeModeWorkspace && !strings.HasPrefix(clean, codeModeWorkspace+"/") {
		return "", errs.InvalidArgument(p + " is outside " + codeModeWorkspace)
	}
	if codeModeMemoryPath(ctx, clean) {
		return "", errs.Permission("saved space memory is disabled for this request")
	}
	return clean, nil
}

func codeModeMemoryPath(ctx context.Context, text string) bool {
	return vmm.ExecutionFrom(ctx).NoMemory && (strings.Contains(text, "AGENTS.md") || strings.Contains(text, ".aseman/"))
}

func codeModeRel(p string) string {
	return strings.TrimPrefix(strings.TrimPrefix(p, codeModeWorkspace), "/")
}

func (s *Service) codeModeCallSandbox(ctx context.Context, spaceID, op string, payload map[string]any) (any, error) {
	if vmm.ExecutionFrom(ctx).NoSandbox {
		return nil, errs.Permission("sandbox access is disabled for this request")
	}
	dir, _ := payload["dir"].(string)
	switch op {
	case "exec":
		command, _ := payload["command"].(string)
		if strings.TrimSpace(command) == "" {
			return nil, errs.InvalidArgument("command is required")
		}
		if cwd, _ := payload["cwd"].(string); strings.TrimSpace(cwd) != "" {
			target, err := codeModeFilePath(ctx, "", cwd)
			if err != nil {
				return nil, err
			}
			command = "cd " + codeModeShellQuote(target) + " && " + command
		}
		return s.codeModeExec(ctx, spaceID, command)
	case "write_files":
		files, _ := payload["files"].([]any)
		if len(files) == 0 {
			return nil, errs.InvalidArgument("files is required")
		}
		return s.codeModeWriteFiles(ctx, spaceID, dir, files)
	case "read_files":
		list, _ := payload["paths"].([]any)
		if len(list) == 0 {
			return nil, errs.InvalidArgument("paths is required")
		}
		out := map[string]any{}
		for _, item := range list {
			p, _ := item.(string)
			target, err := codeModeFilePath(ctx, dir, p)
			if err != nil {
				return nil, err
			}
			content, found, err := s.codeModeReadFile(ctx, spaceID, target)
			if err != nil {
				return nil, err
			}
			if found {
				out[p] = content
			} else {
				out[p] = nil
			}
		}
		return out, nil
	case "edit_file":
		p, _ := payload["path"].(string)
		target, err := codeModeFilePath(ctx, dir, p)
		if err != nil {
			return nil, err
		}
		old, _ := payload["old"].(string)
		repl, _ := payload["new"].(string)
		all, _ := payload["replace_all"].(bool)
		if old == "" {
			return nil, errs.InvalidArgument("old is required")
		}
		content, found, err := s.codeModeReadFile(ctx, spaceID, target)
		if err != nil {
			return nil, err
		}
		if !found {
			return nil, errs.NotFound(p)
		}
		n := strings.Count(content, old)
		switch {
		case n == 0:
			return nil, errs.InvalidArgument("old text not found in " + p)
		case n > 1 && !all:
			return nil, errs.InvalidArgument(fmt.Sprintf("old text occurs %d times in %s: give more context or replace_all", n, p))
		}
		if !all {
			n = 1
		}
		if err := s.codeModeStoreFile(ctx, spaceID, target, []byte(strings.Replace(content, old, repl, n))); err != nil {
			return nil, err
		}
		return map[string]any{"replaced": n}, nil
	case "list", "delete":
		p, _ := payload["path"].(string)
		if op == "list" && strings.TrimSpace(p) == "" {
			p = codeModeWorkspace
		}
		target, err := codeModeFilePath(ctx, dir, p)
		if err != nil {
			return nil, err
		}
		raw, err := s.codeModeDispatch(ctx, "spaces", "sandbox_files", map[string]any{
			"space": spaceID, "operation": op, "path": codeModeRel(target), "wake": true,
		})
		if err != nil {
			return nil, err
		}
		var out map[string]any
		if err := json.Unmarshal(raw, &out); err != nil {
			return nil, err
		}
		return out, nil
	default:
		return nil, errs.NotFound("sandbox operation " + op)
	}
}

func (s *Service) codeModeExec(ctx context.Context, spaceID, command string) (map[string]any, error) {
	if codeModeMemoryPath(ctx, command) {
		return nil, errs.Permission("saved space memory is disabled for this request")
	}
	raw, err := s.codeModeDispatch(ctx, "spaces", "ask", map[string]any{
		"space": spaceID, "room": codeModeRoom(ctx), "bot": "sandbox", "body": command, "raw": true,
	})
	if err != nil {
		return nil, err
	}
	var out struct {
		ExitCode *int   `json:"exit_code"`
		Output   string `json:"output"`
		Reply    string `json:"reply"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	code := -1
	if out.ExitCode != nil {
		code = *out.ExitCode
	}
	output := out.Output
	if out.ExitCode == nil && output == "" {
		output = out.Reply
	}
	return map[string]any{"exit_code": code, "output": output}, nil
}

func (s *Service) codeModeReadFile(ctx context.Context, spaceID, target string) (string, bool, error) {
	raw, err := s.codeModeDispatch(ctx, "spaces", "sandbox_files", map[string]any{
		"space": spaceID, "operation": "read", "path": codeModeRel(target),
	})
	if err != nil {
		return "", false, err
	}
	var out struct {
		Content  *string `json:"content"`
		Missing  bool    `json:"missing"`
		Asleep   bool    `json:"asleep"`
		ErrorMsg string  `json:"error"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", false, err
	}
	switch {
	case out.Content != nil:
		return *out.Content, true, nil
	case out.Missing:
		return "", false, nil
	case out.Asleep:
		// The stored files could not answer: the computer reads it.
		res, err := s.codeModeExec(ctx, spaceID, "cat -- "+codeModeShellQuote(target))
		if err != nil {
			return "", false, err
		}
		if res["exit_code"] != 0 {
			return "", false, nil
		}
		return res["output"].(string), true, nil
	}
	return "", false, errs.New(errs.CodeUnavailable, "could not read "+target+": "+out.ErrorMsg)
}

func (s *Service) codeModeStoreFile(ctx context.Context, spaceID, target string, data []byte) error {
	raw, err := s.codeModeDispatch(ctx, "spaces", "sandbox_files", map[string]any{
		"space": spaceID, "operation": "write", "path": codeModeRel(target),
		"data_base64": base64.StdEncoding.EncodeToString(data), "wake": true,
	})
	if err != nil {
		return err
	}
	var out struct {
		OK    *bool  `json:"ok"`
		Error string `json:"error"`
	}
	if json.Unmarshal(raw, &out) == nil && out.OK != nil && !*out.OK {
		return errs.New(errs.CodeUnavailable, "could not write "+target+": "+out.Error)
	}
	return nil
}

type codeModeFile struct {
	Path string `json:"p"`
	Data string `json:"d"` // base64
}

// codeModeWriteFiles writes small files together, several per command, and
// large ones one by one through the provider.
func (s *Service) codeModeWriteFiles(ctx context.Context, spaceID, dir string, items []any) (map[string]any, error) {
	var batch []codeModeFile
	size := 0
	var written []string
	flush := func() error {
		if len(batch) == 0 {
			return nil
		}
		if err := s.codeModeWriteBatch(ctx, spaceID, batch); err != nil {
			return err
		}
		for _, f := range batch {
			written = append(written, f.Path)
		}
		batch, size = nil, 0
		return nil
	}
	for _, item := range items {
		m, _ := item.(map[string]any)
		p, _ := m["path"].(string)
		target, err := codeModeFilePath(ctx, dir, p)
		if err != nil {
			return nil, err
		}
		var data []byte
		if b64, _ := m["data_base64"].(string); b64 != "" {
			if data, err = base64.StdEncoding.DecodeString(b64); err != nil {
				return nil, errs.InvalidArgument("invalid data_base64 for " + p)
			}
		} else {
			content, _ := m["content"].(string)
			data = []byte(content)
		}
		encoded := base64.StdEncoding.EncodeToString(data)
		if len(encoded) > codeModeWriteChunk {
			if err := flush(); err != nil {
				return nil, err
			}
			if err := s.codeModeStoreFile(ctx, spaceID, target, data); err != nil {
				return nil, err
			}
			written = append(written, target)
			continue
		}
		if size+len(encoded) > codeModeWriteChunk {
			if err := flush(); err != nil {
				return nil, err
			}
		}
		batch = append(batch, codeModeFile{Path: target, Data: encoded})
		size += len(encoded) + len(target)
	}
	if err := flush(); err != nil {
		return nil, err
	}
	return map[string]any{"written": written}, nil
}

// codeModeWriteScript writes files given as base64 JSON, refusing any path
// that resolves outside /workspace. It holds no single quote, so it is quoted
// as one shell word.
const codeModeWriteScript = `import os,json,base64,sys
root=os.path.realpath("/workspace")
files=json.loads(base64.b64decode(sys.argv[1]))
for f in files:
  t=os.path.realpath(f["p"])
  if t!=root and not t.startswith(root+"/"): raise SystemExit("path escapes workspace: "+f["p"])
for f in files:
  t=os.path.realpath(f["p"]); os.makedirs(os.path.dirname(t),exist_ok=True)
  open(t,"wb").write(base64.b64decode(f["d"]))
print(len(files))`

func (s *Service) codeModeWriteBatch(ctx context.Context, spaceID string, files []codeModeFile) error {
	if len(files) == 1 {
		data, _ := base64.StdEncoding.DecodeString(files[0].Data)
		return s.codeModeStoreFile(ctx, spaceID, files[0].Path, data)
	}
	payload, _ := json.Marshal(files)
	command := "python3 -c " + codeModeShellQuote(codeModeWriteScript) + " " + base64.StdEncoding.EncodeToString(payload)
	res, err := s.codeModeExec(ctx, spaceID, command)
	if err != nil {
		return err
	}
	if res["exit_code"] != 0 {
		return errs.New(errs.CodeUnavailable, fmt.Sprintf("writing files failed: %v", res["output"]))
	}
	return nil
}

func codeModeShellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'"'"'`) + "'"
}

func (s *Service) codeModeCallAgent(ctx context.Context, spaceID, slug string, payload map[string]any) (any, error) {
	task, _ := payload["task"].(string)
	if strings.TrimSpace(task) == "" {
		return nil, errs.InvalidArgument("task is required")
	}
	room := codeModeRoom(ctx)
	if room == "" {
		return nil, errs.InvalidArgument("agents take tasks in a room: this call has none")
	}
	agents, err := s.codeModeAgents(ctx, spaceID)
	if err != nil {
		return nil, err
	}
	var agent *codeModeAgent
	for i := range agents {
		if agents[i].Slug == slug || strings.EqualFold(agents[i].Name, slug) {
			agent = &agents[i]
			break
		}
	}
	if agent == nil {
		return nil, errs.NotFound("agent " + slug)
	}
	// The task tag lets a busy agent take it as a parallel instance (team.py).
	raw, err := s.codeModeDispatch(ctx, "spaces", "message_send", map[string]any{
		"space": spaceID, "room": room, "body": "@" + agent.Name + " [task " + codeModeTaskTag() + "] " + task,
		"mentions": []string{agent.AccountID}, "wait": true,
	})
	if err != nil {
		return nil, err
	}
	var sent struct {
		Replies []struct {
			BotID string `json:"bot_id"`
			Reply string `json:"reply"`
		} `json:"replies"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(raw, &sent); err != nil {
		return nil, err
	}
	for _, r := range sent.Replies {
		if r.BotID == agent.BotID {
			answer := strings.TrimSpace(r.Reply)
			if answer == "" {
				answer = "(the agent answered with no text)"
			}
			return map[string]any{"agent": agent.Name, "answer": answer}, nil
		}
	}
	if sent.Error != "" {
		return nil, errs.New(errs.CodeUnavailable, sent.Error)
	}
	return nil, errs.New(errs.CodeUnavailable, agent.Name+" did not take the task")
}

func codeModeTaskTag() string {
	b := make([]byte, 5)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
