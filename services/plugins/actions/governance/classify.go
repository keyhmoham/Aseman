package governance

import (
	"encoding/json"
	"net/url"
	"regexp"
	"strings"

	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
)

// What an action does is decided here, once, so that every enforcement point
// and every policy speaks of the same effects. Anything not positively a read
// is at least a write.

// platformEffects are the platform actions agents call through the gateway.
var platformEffects = map[string]string{
	"spaces.message_send": gate.EffectWrite, "spaces.message_list": gate.EffectRead, "spaces.message_search": gate.EffectRead,
	"users.dm_send": gate.EffectWrite, "users.dm_list": gate.EffectRead,
	"spaces.tools_list": gate.EffectRead, "spaces.sandbox_files": gate.EffectRead,
	"spaces.members_list": gate.EffectRead, "spaces.bots_list": gate.EffectRead, "spaces.room_get": gate.EffectRead,
	"spaces.room_list": gate.EffectRead, "spaces.file_get": gate.EffectRead, "spaces.file_list": gate.EffectRead,
	"users.account_get": gate.EffectRead, "users.search": gate.EffectRead,
	"spaces.agent_log": gate.EffectWrite, "spaces.agent_recruit": gate.EffectWrite, "spaces.agent_hire": gate.EffectWrite,
	"market.catalog": gate.EffectRead,
}

// toolEffects are the project's platform tools, and the tools of the
// namespaces that serve agents (mail, calendar, host access, channels).
var toolEffects = map[string]string{
	"file_read": gate.EffectRead, "room_info": gate.EffectRead, "ask_user": gate.EffectRead,
	"routine_list": gate.EffectRead, "routine_get": gate.EffectRead, "proxy_list": gate.EffectRead, "proxy_get": gate.EffectRead,
	"appui_status": gate.EffectRead, "opencode_status": gate.EffectRead, "opencode_models": gate.EffectRead,
	"desk_state": gate.EffectRead, "db_tables": gate.EffectRead, "db_read": gate.EffectRead,
	"secret_request": gate.EffectRead, "computer_help": gate.EffectRead, "offer_task": gate.EffectRead,
	"routine_delete": gate.EffectDelete, "proxy_delete": gate.EffectDelete,
	"gmail_search": gate.EffectRead, "gmail_read": gate.EffectRead, "gmail_draft": gate.EffectWrite, "gmail_send": gate.EffectSend,
	"calendar_events": gate.EffectRead, "calendar_create": gate.EffectSend,
	"host_read": gate.EffectRead, "host_list": gate.EffectRead, "host_write": gate.EffectWrite, "host_exec": gate.EffectWrite,
	"slack_post": gate.EffectSend, "teams_post": gate.EffectSend, "sms_send": gate.EffectSend,
}

var (
	readWords   = []string{"get", "list", "search", "read", "find", "fetch", "query", "lookup", "describe", "view", "show", "status", "count", "check", "retrieve", "download", "preview", "inspect", "info"}
	sendWords   = []string{"send", "post", "email", "mail", "message", "reply", "invite", "share", "publish", "notify", "tweet", "comment", "forward", "sms", "text"}
	payWords    = []string{"pay", "charge", "transfer", "purchase", "buy", "order", "checkout", "refund", "invoice", "payout", "withdraw", "subscribe"}
	signWords   = []string{"sign", "esign", "signature", "notarize", "accept_contract", "approve_contract"}
	deleteWords = []string{"delete", "remove", "destroy", "drop", "purge", "erase", "archive", "cancel", "revoke", "trash", "wipe"}
	wordSplit   = regexp.MustCompile(`[^a-z0-9]+`)
)

// effectFromName classifies a function or tool by the words in its name.
func effectFromName(name string) string {
	words := wordSplit.Split(strings.ToLower(camelSplit(name)), -1)
	has := func(list []string) bool {
		for _, w := range words {
			for _, l := range list {
				if w == l {
					return true
				}
			}
		}
		return false
	}
	switch {
	case has(payWords):
		return gate.EffectPay
	case has(signWords):
		return gate.EffectSign
	case has(deleteWords):
		return gate.EffectDelete
	case has(sendWords):
		return gate.EffectSend
	case has(readWords):
		return gate.EffectRead
	}
	return gate.EffectWrite
}

func camelSplit(s string) string {
	var b strings.Builder
	for i, r := range s {
		if i > 0 && r >= 'A' && r <= 'Z' {
			b.WriteByte('_')
		}
		b.WriteRune(r)
	}
	return b.String()
}

var (
	urlRE        = regexp.MustCompile(`https?://[^\s'"<>|;)]+`)
	readPrograms = map[string]bool{"ls": true, "cat": true, "head": true, "tail": true, "grep": true, "rg": true, "find": true, "pwd": true,
		"echo": true, "wc": true, "stat": true, "file": true, "du": true, "df": true, "ps": true, "which": true, "less": true, "tree": true,
		"sort": true, "uniq": true, "cut": true, "jq": true, "diff": true, "date": true, "whoami": true, "uname": true, "env": true, "true": true}
	readGit     = map[string]bool{"status": true, "log": true, "diff": true, "show": true, "branch": true, "remote": true, "rev-parse": true, "ls-files": true}
	sendCommand = regexp.MustCompile(`(^|[;&|]\s*)(sendmail|mail|mailx|mutt|swaks)\b`)
	uploadCurl  = regexp.MustCompile(`\b(curl|wget|http|httpie)\b[^;&|]*(\s-X\s*(POST|PUT|PATCH|DELETE)|\s(-d|--data[a-z-]*|-F|--form|-T|--upload-file|--post-data|--post-file)\b)`)
	externalCmd = regexp.MustCompile(`(^|[;&|]\s*)(git\s+push|npm\s+publish|yarn\s+publish|twine\s+upload|docker\s+push|scp|rsync\s+[^;&|]*\S+:|ssh|ftp|sftp|nc|ncat|telnet)\b`)
	deleteCmd   = regexp.MustCompile(`\brm\s+(-[a-zA-Z]*[rR][a-zA-Z]*\s+)+(--no-preserve-root\s+)?(/|/workspace/?|~/?|\*|/workspace/\*|\$HOME/?)(\s|$|;|&)|\b(DROP\s+(TABLE|DATABASE|SCHEMA)|TRUNCATE\s+TABLE)\b|\bmkfs\b|\bdd\s+[^;&|]*of=/dev/`)
	pipeSplit   = regexp.MustCompile(`\|\||&&|;|\|`)
	// redirectNoise are redirections that write nothing anyone keeps.
	redirectNoise = regexp.MustCompile(`\d?>&\d|\d?>\s*/dev/null`)
)

// commandEffect classifies a project computer command.
func commandEffect(command string) string {
	c := strings.TrimSpace(command)
	switch {
	case c == "":
		return gate.EffectRead
	case deleteCmd.MatchString(c):
		return gate.EffectDelete
	case sendCommand.MatchString(c):
		return gate.EffectSend
	case uploadCurl.MatchString(c) && hasRemoteURL(c), externalCmd.MatchString(c):
		return gate.EffectExternal
	}
	if strings.Contains(redirectNoise.ReplaceAllString(c, ""), ">") {
		return gate.EffectWrite
	}
	for _, part := range pipeSplit.Split(c, -1) {
		fields := strings.Fields(part)
		if len(fields) == 0 {
			continue
		}
		prog := fields[0]
		if prog == "sudo" && len(fields) > 1 {
			prog = fields[1]
			fields = fields[1:]
		}
		if prog == "git" && len(fields) > 1 && readGit[fields[1]] {
			continue
		}
		if prog == "find" && (strings.Contains(part, "-delete") || strings.Contains(part, "-exec")) {
			return gate.EffectWrite
		}
		if !readPrograms[prog] {
			return gate.EffectWrite
		}
	}
	return gate.EffectRead
}

func hasRemoteURL(c string) bool {
	for _, u := range urlRE.FindAllString(c, -1) {
		h := hostOf(u)
		if h != "" && h != "localhost" && h != "127.0.0.1" && h != "::1" && !strings.HasSuffix(h, ".internal") {
			return true
		}
	}
	return false
}

func hostOf(raw string) string {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return ""
	}
	return strings.ToLower(u.Hostname())
}

func decodeJSON(raw json.RawMessage) any {
	var v any
	if json.Unmarshal(raw, &v) != nil {
		return nil
	}
	return v
}

// argString reads a string argument by any of the given names.
func argString(args map[string]any, names ...string) string {
	for _, n := range names {
		if v, ok := args[n].(string); ok && strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func argList(args map[string]any, names ...string) []string {
	var out []string
	for _, n := range names {
		switch v := args[n].(type) {
		case string:
			for _, p := range strings.Split(v, ",") {
				if p = strings.TrimSpace(p); p != "" {
					out = append(out, p)
				}
			}
		case []any:
			for _, item := range v {
				if s, ok := item.(string); ok && strings.TrimSpace(s) != "" {
					out = append(out, strings.TrimSpace(s))
				}
			}
		}
	}
	return out
}

// Normalize fills in what the request does from what it names: the platform
// tool behind a spaces.ask, the command, URL, file, recipients and text in
// its arguments, and its effect.
func Normalize(req gate.Request) gate.Request {
	args, _ := decodeJSON(req.Args).(map[string]any)
	if args == nil {
		args = map[string]any{}
	}
	// spaces.ask is three things: a platform tool, a command on the project
	// computer, or a question to an app or agent.
	if req.Kind == gate.KindPlatform && req.Tool == "spaces.ask" {
		if tool := argString(args, "tool"); tool != "" {
			req.Kind, req.Tool = gate.KindTool, tool
			inner, _ := args["args"].(map[string]any)
			if inner == nil {
				inner = map[string]any{}
			}
			raw, _ := json.Marshal(inner)
			req.Args, args = raw, inner
		} else if bot := argString(args, "bot"); bot == "sandbox" {
			req.Kind, req.Tool, req.Command = gate.KindSandbox, "sandbox_exec", argString(args, "body")
		} else {
			req.Kind, req.App = gate.KindApp, bot
			if req.Function == "" {
				req.Function = "ask"
			}
			req.Text = argString(args, "body")
		}
	}
	if req.Tool == "sandbox_exec" && req.Command == "" {
		req.Command = argString(args, "command", "input", "cmd")
		req.Kind = gate.KindSandbox
	}
	if req.URL == "" {
		req.URL = argString(args, "url", "href", "link", "endpoint")
		if req.URL == "" && req.Command != "" {
			req.URL = urlRE.FindString(req.Command)
		}
	}
	if req.Path == "" {
		req.Path = argString(args, "path", "file", "file_path", "filename")
	}
	if len(req.Recipients) == 0 {
		req.Recipients = argList(args, "to", "cc", "bcc", "recipients", "recipient", "channel", "phone", "email", "attendees")
	}
	if req.Text == "" {
		req.Text = argString(args, "body", "text", "message", "content")
	}
	if req.Effect == "" {
		req.Effect = effectOf(req)
	}
	return req
}

func effectOf(req gate.Request) string {
	switch req.Kind {
	case gate.KindPlatform:
		if e, ok := platformEffects[req.Tool]; ok {
			return e
		}
		return effectFromName(req.Tool)
	case gate.KindSandbox:
		return commandEffect(req.Command)
	case gate.KindTool, gate.KindHost, gate.KindChannel:
		if e, ok := toolEffects[req.Tool]; ok {
			if req.Tool == "host_exec" {
				if commandEffect(req.Command) == gate.EffectRead {
					return gate.EffectRead
				}
			}
			return e
		}
		return effectFromName(req.Tool)
	case gate.KindApp, gate.KindMCP:
		if req.ReadOnly != nil && *req.ReadOnly {
			return gate.EffectRead
		}
		if req.Destroys != nil && *req.Destroys {
			return gate.EffectDelete
		}
		name := req.Function
		if req.Kind == gate.KindMCP && req.MCPTool != "" {
			name = req.MCPTool
		}
		if name == "" || name == "ask" {
			return gate.EffectWrite
		}
		return effectFromName(name)
	case gate.KindAgent:
		return gate.EffectWrite
	}
	return gate.EffectWrite
}

// Target is what a standing grant and the audit trail name the action's
// object by: the program run, the app function, the recipients, the host.
func Target(req gate.Request) string {
	switch {
	case req.Kind == gate.KindSandbox || req.Tool == "host_exec":
		if f := strings.Fields(req.Command); len(f) > 0 {
			return "command:" + f[0]
		}
	case req.Kind == gate.KindMCP && req.MCPServer != "":
		return "mcp:" + req.MCPServer + "/" + req.MCPTool
	case req.Kind == gate.KindApp && req.App != "":
		return "app:" + req.App + "/" + req.Function
	case len(req.Recipients) > 0:
		return "to:" + strings.ToLower(strings.Join(req.Recipients, ","))
	case req.URL != "":
		return "host:" + hostOf(req.URL)
	case req.Path != "":
		return "file:" + req.Path
	}
	return ""
}
