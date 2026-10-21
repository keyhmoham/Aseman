package tools

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/tools/mechanisms/mcp"
	"github.com/aseman/aseman/plugins/actions/tools/models"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Every tool backend is an MCP server, whatever its mode; what differs is
// where it answers and how the node is let in:
//
//	external   the server's URL, with shared or per-person credentials
//	managed    the backend's Nomad service on the node's network, with the
//	           node's runtime credential and the call's execution scope
//	installed  the backend in the space's sandbox, reached through that
//	           space's gateway proxy, with the same credential and scope
//
// So agents (as microtools, through spaces.ask) and frontends (through
// tools.invoke and the frontend actions) call every tool the same way.

// endpoint is one resolved MCP server of a tool for one call.
type endpoint struct {
	URL     string
	Headers map[string]string
	Client  *mcp.Client
	// Starting is how long the backend may take to start answering: one
	// in the space's computer may have just been woken (or started) for
	// this call, and the call waits for it rather than failing.
	Starting time.Duration
}

// installedStart is how long a backend installed in a space's computer is
// given to answer after the computer wakes or the backend starts.
const installedStart = 90 * time.Second

// mcpPath is where a backend serves MCP: the runtime image's fixed path, or
// what a docker image declared.
func mcpPath(tool *models.Tool) string {
	if tool.Runtime == models.RuntimeDocker && strings.HasPrefix(tool.URL, "/") {
		return tool.URL
	}
	return "/mcp"
}

// endpointFor resolves where a tool answers a call made by [actor] in
// [spaceID] (empty outside a space; an installed tool needs one).
func (s *Service) endpointFor(ctx context.Context, tool *models.Tool, rec *bot.Bot, actor identity.ID, spaceID string) (*endpoint, error) {
	switch tool.EffectiveMode() {
	case models.ModeExternal:
		headers, err := s.headers(ctx, tool, actor, spaceID)
		if err != nil {
			return nil, err
		}
		return &endpoint{URL: tool.URL, Headers: headers, Client: s.Client}, nil
	case models.ModeManaged:
		base := tool.Endpoint
		if base == "" {
			if vm := s.K.VMMFor(vmm.Type(rec.VMType)); vm != nil {
				if got, err := vm.GetVM(ctx, rec.VMID); err == nil {
					base = got.Address
				}
			}
		}
		if base == "" {
			return nil, errs.New(errs.CodeUnavailable, "the tool's backend has no address yet")
		}
		headers, err := s.scopeHeaders(ctx, tool, rec, actor, spaceID)
		if err != nil {
			return nil, err
		}
		return &endpoint{URL: strings.TrimRight(base, "/") + mcpPath(tool), Headers: headers, Client: s.Internal}, nil
	case models.ModeInstalled:
		if spaceID == "" {
			return nil, errs.InvalidArgument("an installed tool runs inside a space: call it from one")
		}
		target, err := s.install(ctx, tool, rec, spaceID)
		if err != nil {
			return nil, err
		}
		headers, err := s.scopeHeaders(ctx, tool, rec, actor, spaceID)
		if err != nil {
			return nil, err
		}
		if target.Token != "" {
			headers["Authorization"] = "Bearer " + target.Token
		}
		return &endpoint{URL: strings.TrimRight(target.TargetURL, "/") + mcpPath(tool), Headers: headers, Client: s.Internal, Starting: installedStart}, nil
	}
	return nil, errs.InvalidArgument("unknown tool backend mode " + tool.Mode)
}

// rpc runs one MCP method on a tool's backend.
func (s *Service) rpc(ctx context.Context, ep *endpoint, method string, params any) (map[string]any, error) {
	headers, err := ep.Client.Session(ctx, ep.URL, ep.Headers)
	// A backend still starting (its computer just woke) is waited for.
	for wait, deadline := time.Second, time.Now().Add(ep.Starting); err != nil && !refused(err) && time.Now().Add(wait).Before(deadline); wait = min(2*wait, 5*time.Second) {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(wait):
		}
		headers, err = ep.Client.Session(ctx, ep.URL, ep.Headers)
	}
	if err != nil {
		return nil, errs.New(errs.CodeUnavailable, "the tool's backend is not answering: "+err.Error())
	}
	return ep.Client.RPC(ctx, ep.URL, headers, method, params)
}

// refused is a backend that answered and said no: no reason to wait for it.
func refused(err error) bool { return strings.Contains(err.Error(), "initialization was refused") }

// InvokeTool runs one microtool of a tool for the caller of the current
// execution: body is {"function", "payload"}; the reply is the MCP result.
// It is the one way into every backend mode (spaces.ask routes here).
func (s *Service) InvokeTool(ctx context.Context, botID, body string) (string, error) {
	rec, err := s.bot(ctx, botID)
	if err != nil {
		return "", err
	}
	return s.invokeBot(ctx, rec, body)
}

// InvokeMCP is InvokeTool addressed by the bot's VM id (the logical tool VM
// adapter knows only that).
func (s *Service) InvokeMCP(ctx context.Context, vmID, body string) (string, error) {
	var bots []bot.Bot
	if e := s.R.List(ctx, "bots", filterEq("vm_id", vmID), &bots); e != nil {
		return "", e
	}
	if len(bots) == 0 {
		return "", errs.NotFound("tool bot")
	}
	return s.invokeBot(ctx, &bots[0], body)
}

func (s *Service) invokeBot(ctx context.Context, rec *bot.Bot, body string) (string, error) {
	execution := vmm.ExecutionFrom(ctx)
	actor := helper.Actor(ctx)
	if execution.ActorID != "" {
		id, e := identity.Parse(execution.ActorID)
		if e != nil {
			return "", e
		}
		actor = id
	}
	if actor.IsZero() {
		return "", errs.Unauthenticated("tool caller required")
	}
	if execution.SpaceID != "" {
		sp, e := identity.Parse(execution.SpaceID)
		if e != nil {
			return "", e
		}
		if e = helper.CheckSpaceAccess(ctx, s.R, actor, sp, identity.ID{}, true); e != nil {
			return "", e
		}
		if e = helper.CheckSpaceAccess(ctx, s.R, rec.AccountID, sp, identity.ID{}, false); e != nil {
			return "", e
		}
	}
	var tool models.Tool
	if e := s.R.GetString(ctx, "tool_registry", rec.ID.String(), &tool); e != nil {
		return "", e
	}
	var in struct {
		Function string         `json:"function"`
		Payload  map[string]any `json:"payload"`
	}
	if e := json.Unmarshal([]byte(body), &in); e != nil || in.Function == "" {
		// A tool asked in plain words (by an agent that was given no
		// microtools) gets the request as the input of a tool named "ask",
		// the convention for a backend that takes free text.
		in.Function, in.Payload = "ask", map[string]any{"request": body}
	}
	if in.Payload == nil {
		in.Payload = map[string]any{}
	}
	ep, err := s.endpointFor(ctx, &tool, rec, actor, execution.SpaceID)
	if err != nil {
		return "", err
	}
	result, err := s.rpc(ctx, ep, "tools/call", map[string]any{"name": in.Function, "arguments": in.Payload})
	if err != nil {
		return "", err
	}
	b, err := json.Marshal(result)
	return string(b), err
}

// microtools lists what a tool's backend offers, live.
func (s *Service) microtools(ctx context.Context, tool *models.Tool, rec *bot.Bot, actor identity.ID, spaceID string) ([]map[string]any, error) {
	ep, err := s.endpointFor(ctx, tool, rec, actor, spaceID)
	if err != nil {
		return nil, err
	}
	result, err := s.rpc(ctx, ep, "tools/list", map[string]any{})
	if err != nil {
		return nil, err
	}
	return commandDefs(result), nil
}

// rememberMicrotools keeps what a managed or installed backend said it
// offers, so agents are given its microtools without waking it.
func (s *Service) rememberMicrotools(ctx context.Context, tool *models.Tool, commands []map[string]any) {
	if tool.EffectiveMode() == models.ModeExternal || len(commands) == 0 {
		return
	}
	before, _ := json.Marshal(tool.Commands)
	after, _ := json.Marshal(commands)
	if string(before) == string(after) {
		return
	}
	tool.Commands = commands
	if err := s.R.UpdateString(ctx, "tool_registry", tool.ID, tool); err == nil {
		s.forgetCommands(tool.BotID)
	}
}

// --- installed backends ------------------------------------------------------

// installDir is where a tool lives in a space's sandbox.
func installDir(botID string) string { return "/workspace/.aseman/tools/" + botID }

// installPort is the sandbox port an Elpian VM or QuickJS backend serves on:
// fixed per tool, so it is found again after the sandbox sleeps.
func installPort(botID string) int {
	h := fnv.New32a()
	_, _ = h.Write([]byte(botID))
	return 20000 + int(h.Sum32()%20000)
}

// programVersion fingerprints a program, so an installed backend running an
// older one is restarted with the new one.
func programVersion(p *Program) string {
	sum := sha256.Sum256([]byte(p.Engine + "\x00" + p.Language + "\x00" + p.Source))
	return hex.EncodeToString(sum[:8])
}

// shellQuote quotes a value for /bin/sh.
func shellQuote(v string) string { return "'" + strings.ReplaceAll(v, "'", `'\''`) + "'" }

// install makes sure a tool runs in a space's sandbox and returns the gateway
// proxy that reaches it: an Elpian VM or QuickJS backend is written into the
// sandbox and started on the tool runtime baked into the sandbox image; a
// docker backend runs as a sidecar sharing the sandbox's network.
func (s *Service) install(ctx context.Context, tool *models.Tool, rec *bot.Bot, spaceID string) (*toolProxyTarget, error) {
	space, err := identity.Parse(spaceID)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space")
	}
	internal := helper.WithInternalAccess(ctx)
	port := installPort(rec.ID.String())
	switch tool.Runtime {
	case models.RuntimeElpian, models.RuntimeQuickJS:
		if err := s.installProgram(internal, space, tool, port); err != nil {
			return nil, err
		}
	case models.RuntimeDocker:
		port = int(tool.Port)
		env, err := s.runtimeEnv(tool.RuntimeKey, port)
		if err != nil {
			return nil, err
		}
		name := "tool-" + rec.ID.String()[16:]
		if err := bridge.Invoke(internal, s.K, "spaces", "SandboxSidecar", []any{internal, space, name, tool.Image, env}); err != nil {
			return nil, err
		}
	default:
		return nil, errs.InvalidArgument("an installed tool runs on elpian, quickjs or docker")
	}
	var target toolProxyTarget
	if err := bridge.Invoke(internal, s.K, "spaces", "EnsureToolProxy", []any{internal, space, rec.AccountID, port, "Tool · " + rec.Name}, &target); err != nil {
		return nil, err
	}
	return &target, nil
}

// toolProxyTarget mirrors spaces.ToolProxyTarget across the bridge.
type toolProxyTarget struct {
	ProxyID   string `json:"proxy_id"`
	TargetURL string `json:"target_url"`
	Token     string `json:"token,omitempty"`
	Path      string `json:"path"`
}

// installChunk bounds one write of the program into the sandbox (one shell
// command each).
const installChunk = 48 << 10

// installProgram starts an Elpian VM or QuickJS backend in the sandbox unless
// one running the current program already answers on its port.
func (s *Service) installProgram(ctx context.Context, space identity.ID, tool *models.Tool, port int) error {
	botID := tool.BotID
	program, err := s.program(ctx, botID)
	if err != nil {
		return err
	}
	version := programVersion(program)
	health := fmt.Sprintf("curl -sf -m 3 http://127.0.0.1:%d/health | grep -q %s", port, shellQuote(version))
	if _, err := s.sandboxExec(ctx, space, health); err == nil {
		return nil
	}
	dir := installDir(botID)
	raw, _ := json.Marshal(program)
	encoded := base64.StdEncoding.EncodeToString(raw)
	if _, err := s.sandboxExec(ctx, space, "mkdir -p "+shellQuote(dir)+" && : > "+shellQuote(dir+"/program.b64")); err != nil {
		return err
	}
	for len(encoded) > 0 {
		n := min(installChunk, len(encoded))
		if _, err := s.sandboxExec(ctx, space, "printf %s "+shellQuote(encoded[:n])+" >> "+shellQuote(dir+"/program.b64")); err != nil {
			return err
		}
		encoded = encoded[n:]
	}
	env, err := s.runtimeEnv(tool.RuntimeKey, port)
	if err != nil {
		return err
	}
	env["ASEMAN_TOOL_ENGINE"] = program.Engine
	env["ASEMAN_TOOL_PROGRAM_FILE"] = dir + "/program.json"
	env["ASEMAN_TOOL_VERSION"] = version
	var assign []string
	for k, v := range env {
		assign = append(assign, k+"="+shellQuote(v))
	}
	start := fmt.Sprintf("cd %[1]s && base64 -d program.b64 > program.json"+
		" && (pkill -f %[2]s 2>/dev/null; true)"+
		" && (env %[3]s nohup node /opt/aseman-tool-runtime/server.mjs --tool %[4]s > runtime.log 2>&1 < /dev/null &)"+
		" ; for i in $(seq 1 30); do %[5]s && exit 0; sleep 1; done; tail -n 20 runtime.log; exit 1",
		shellQuote(dir), shellQuote(stopPattern(botID)), strings.Join(assign, " "), shellQuote(botID), health)
	if out, err := s.sandboxExec(ctx, space, start); err != nil {
		return errs.New(errs.CodeUnavailable, "the tool did not start in the space's sandbox: "+strings.TrimSpace(out+" "+err.Error()))
	}
	return nil
}

// stopPattern is the pkill -f pattern of a tool's running backend. It must
// not start with "-" (pkill reads "--tool …" as an option and kills nothing)
// and must not match the shell running the restart, whose command line holds
// the pattern itself: the bracket matches "server.mjs" but not "server[.]mjs".
func stopPattern(botID string) string {
	return "server[.]mjs --tool " + botID
}

func (s *Service) sandboxExec(ctx context.Context, space identity.ID, command string) (string, error) {
	var out string
	err := bridge.Invoke(ctx, s.K, "spaces", "SandboxExec", []any{ctx, space, command}, &out)
	return out, err
}
