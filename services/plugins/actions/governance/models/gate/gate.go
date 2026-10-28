// Package gate is the contract between the places agents act through (the
// agent gateway, Code Mode, channels, host access) and the governance
// namespace that decides each action. Callers import this package only; the
// decision itself is reached through the namespace bridge.
package gate

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/pkg/errs"
)

// Kinds of action.
const (
	KindPlatform = "platform" // a platform action (namespace.action) an agent calls
	KindTool     = "tool"     // one of the project's platform tools
	KindSandbox  = "sandbox"  // a command on the project computer
	KindApp      = "app"      // an app's function (wasm, managed, installed)
	KindMCP      = "mcp"      // an external MCP server's tool
	KindAgent    = "agent"    // a hand-off to another agent
	KindHost     = "host"     // a person's own computer, through the desktop app
	KindChannel  = "channel"  // Slack, Teams or SMS
)

// Effects of an action. Anything not positively a read is at least a write.
const (
	EffectRead     = "read"
	EffectWrite    = "write"
	EffectSend     = "send"
	EffectPay      = "pay"
	EffectSign     = "sign"
	EffectDelete   = "delete"
	EffectExternal = "external"
)

// Request is one action an agent is about to take.
type Request struct {
	Kind string `json:"kind"`
	// Tool is the action's name: "spaces.message_send", "sandbox_exec",
	// "gmail_send", "orders/refund", ...
	Tool string          `json:"tool"`
	Args json.RawMessage `json:"args,omitempty"`
	// Effect, when the caller knows it better than a classifier would.
	Effect string `json:"effect,omitempty"`
	// Targets, derived from the arguments by whoever knows their shape.
	Command    string   `json:"command,omitempty"`
	URL        string   `json:"url,omitempty"`
	Path       string   `json:"path,omitempty"`
	App        string   `json:"app,omitempty"`
	Function   string   `json:"function,omitempty"`
	MCPServer  string   `json:"mcp_server,omitempty"`
	MCPTool    string   `json:"mcp_tool,omitempty"`
	ReadOnly   *bool    `json:"read_only,omitempty"`
	Destroys   *bool    `json:"destructive,omitempty"`
	Recipients []string `json:"recipients,omitempty"`
	// Text is what a message says, shown on the approval card.
	Text    string `json:"text,omitempty"`
	Summary string `json:"summary,omitempty"`
	// Who and where.
	SpaceID      string `json:"space_id"`
	RoomID       string `json:"room_id,omitempty"`
	AgentID      string `json:"agent_id,omitempty"`
	AgentName    string `json:"agent_name,omitempty"`
	AgentAccount string `json:"agent_account,omitempty"`
	ActorID      string `json:"actor_id,omitempty"`
	RunID        string `json:"run_id,omitempty"`
	// Initiator is filled from the run's context when empty.
	InitiatorKind string `json:"initiator_kind,omitempty"`
	InitiatorID   string `json:"initiator_id,omitempty"`
}

// Result is the decision. When Allowed, Args and Command carry the request's
// arguments with the person's secrets put in: use them, never the originals.
type Result struct {
	Allowed    bool            `json:"allowed"`
	Decision   string          `json:"decision"`
	Rule       string          `json:"rule,omitempty"`
	Reason     string          `json:"reason,omitempty"`
	AuditID    string          `json:"audit_id,omitempty"`
	ApprovalID string          `json:"approval_id,omitempty"`
	Args       json.RawMessage `json:"args,omitempty"`
	Command    string          `json:"command,omitempty"`
	// Secrets are the values put in, by name, for Finish to redact from the
	// result before a model reads it. Never serialized out of the node.
	Secrets map[string]string `json:"secrets,omitempty"`
}

// Err is the error an agent gets for a refused action.
func (r Result) Err() error {
	if r.Allowed {
		return nil
	}
	msg := r.Reason
	if msg == "" {
		msg = "refused by policy"
	}
	return errs.Permission(msg)
}

// Required reports whether actions must be refused when the governance
// namespace is not loaded.
func Required() bool { return os.Getenv("ASEMAN_GOVERNANCE_REQUIRED") == "1" }

// Check asks the governance namespace to decide an action. With the namespace
// absent it allows (or refuses, when governance is required); any other
// failure to decide refuses.
func Check(ctx context.Context, k api.Kernel, req Request) (Result, error) {
	var out Result
	err := bridge.Invoke(ctx, k, "governance", "Gate", []any{ctx, req}, &out)
	if err == nil {
		return out, out.Err()
	}
	if absent(k) {
		if Required() {
			return Result{Decision: "denied", Reason: "governance is required and not loaded"}, errs.Permission("governance is required and not loaded")
		}
		return Result{Allowed: true, Decision: "allowed", Args: req.Args, Command: req.Command}, nil
	}
	return Result{Decision: "denied", Reason: err.Error()}, err
}

// Finish records how a forwarded action ended and returns its output with the
// secrets that were put in redacted. It never fails its caller.
func Finish(ctx context.Context, k api.Kernel, r Result, output string, actionErr error) string {
	if r.AuditID == "" && len(r.Secrets) == 0 {
		return output
	}
	failure := ""
	if actionErr != nil {
		failure = actionErr.Error()
	}
	if r.AuditID != "" {
		_ = bridge.Invoke(ctx, k, "governance", "Finish", []any{ctx, r.AuditID, failure})
	}
	return Redact(output, r.Secrets)
}

// Redact replaces every secret value in text with [secret:name].
func Redact(text string, secrets map[string]string) string {
	for name, value := range secrets {
		if len(value) < 4 {
			continue
		}
		text = strings.ReplaceAll(text, value, "[secret:"+name+"]")
		// The same value as it appears inside a JSON string.
		if raw, err := json.Marshal(value); err == nil {
			if escaped := string(raw[1 : len(raw)-1]); escaped != value {
				text = strings.ReplaceAll(text, escaped, "[secret:"+name+"]")
			}
		}
	}
	return text
}

func absent(k api.Kernel) bool {
	if k == nil {
		return true
	}
	_, err := k.Resolve("service/governance")
	return err != nil && !errors.Is(err, context.Canceled)
}

// ToolCall is one agent tool served by a namespace other than spaces: spaces
// receives every platform tool call and hands these to their owner's
// AgentTool(ctx, ToolCall) (string, error), after the gate allowed them.
type ToolCall struct {
	Tool         string `json:"tool"`
	Args         string `json:"args"`
	SpaceID      string `json:"space_id"`
	RoomID       string `json:"room_id,omitempty"`
	AgentID      string `json:"agent_id,omitempty"`
	AgentName    string `json:"agent_name,omitempty"`
	AgentAccount string `json:"agent_account,omitempty"`
	ActorID      string `json:"actor_id,omitempty"`
}

// toolOwners are the agent tools other namespaces serve.
var toolOwners = map[string]string{
	"secret_request": "governance", "computer_help": "governance",
	"gmail_search": "google", "gmail_read": "google", "gmail_draft": "google", "gmail_send": "google",
	"calendar_events": "google", "calendar_create": "google",
	"offer_task": "proactive", "task_update": "proactive",
	"host_exec": "hostaccess", "host_read": "hostaccess", "host_write": "hostaccess", "host_list": "hostaccess",
	"slack_post": "channels", "teams_post": "channels", "sms_send": "channels",
}

// ToolOwner is the namespace serving an agent tool, or "" for spaces' own.
func ToolOwner(tool string) string { return toolOwners[tool] }

// OwnedTools lists every tool other namespaces serve, by namespace.
func OwnedTools() map[string][]string {
	out := map[string][]string{}
	for tool, ns := range toolOwners {
		out[ns] = append(out[ns], tool)
	}
	return out
}
