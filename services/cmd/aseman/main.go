// Command aseman is the CLI client for the aseman platform. It talks to
// the action API of any federation node, authenticates and drives the full
// admin/ops surface.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/crypto"
)

const (
	defaultServer = "http://localhost:8080"
	tokenDir      = ".aseman"
	tokenFile     = "token"
	keyFile       = "identity.key"
)

func main() {
	if len(os.Args) < 2 || os.Args[1] == "help" || os.Args[1] == "-h" {
		usage()
		return
	}
	cmd := os.Args[1]
	args := os.Args[2:]

	switch cmd {
	case "login":
		runLogin(args)
	case "logout":
		runLogout()
	case "call":
		runCall(args)
	case "actions":
		runGet("admin/actions_list", args)
	case "plugins":
		runGet("_node/plugins_list", args)
	case "plugins-build":
		runCall(append([]string{"_node.plugins_build"}, args...))
	case "plugins-update":
		runCall(append([]string{"_node.plugins_update"}, args...))
	case "plugins-replace":
		runCall(append([]string{"_node.plugins_replace"}, args...))
	case "plugins-stop":
		runCall(append([]string{"_node.plugins_stop"}, args...))
	case "plugins-load":
		runCall(append([]string{"_node.plugins_load"}, args...))
	case "plugins-unload":
		runCall(append([]string{"_node.plugins_unload"}, args...))
	case "plugins-active":
		runCall(append([]string{"_node.plugins_set_active"}, args...))
	case "models":
		runGet("admin/models_list", args)
	case "tables":
		runCall(append([]string{"admin.tables_list"}, args...))
	case "wiring":
		runGet("admin/wiring", args)
	case "telemetry":
		runGet("admin/telemetry", args)
	case "logs":
		runGet("admin/logs", args)
	case "nodes":
		runGet("federation/nodes_list", args)
	case "whoami":
		runGet("auth/whoami", args)
	case "lead":
		runLead(args)
	case "workflow", "workflows":
		runWorkflow(args)
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", cmd)
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Print(`aseman - CLI for the aseman federated VM platform

Usage:
  aseman <command> [flags] [args]

Commands:
  login <handle> <password>   Authenticate and store the session token
  logout                      Remove the stored session token
  whoami                      Show the current caller
  call <ns>.<action> [k=v ...]  Call any action; k=v pairs become the JSON body
                             (or pass --json '<json>' for a raw body)
  actions                     List namespaces and actions (admin)
  plugins                     List plugins and states (admin)
  plugins-build source=<folder>  Build a versioned plugin on the node
  plugins-load path=<file.so>    Load a native plugin (or name=<name> to restart)
  plugins-replace name=<name> path=<file.so>  Replace a loaded plugin
  plugins-update name=<name> --json <body>  Update plugin configuration
  plugins-stop name=<name>       Drain and stop a plugin
  plugins-unload name=<name>       Unload a plugin
  plugins-active category=<category> plugin=<name>  Reprogram the active adapter
  models                      List database models (admin)
  tables model=<name> [limit=N]  List records of a model
  wiring                      Show adapter wiring (admin)
  telemetry                   Node telemetry snapshot (admin)
  logs [limit=N]              Recent system logs (admin)
  nodes                       List federation nodes
  lead setup|run|questions|answer  Manage the built-in project lead
  workflow validate|plan|run|runs|get|cancel|schema  The workflow installer
                             (aseman workflow help)

Flags (global):
  --server <url>   Node API URL (default http://localhost:8080)
  --token <tok>    Explicit bearer token (default: stored token)
  --json '<json>'  Raw JSON body for call

Examples:
  aseman login alice secret1234
  aseman call auth.whoami
  aseman call spaces.space_create name="my space"
  aseman call bots.bot_create name=helper vm_type=docker image_ref=busybox
  aseman call finance.wallet_get
  aseman call admin.table_get model=accounts id=<universal-id>
`)
}

func flagsFor(args []string) (server, token string, jsonBody string, positional []string) {
	server = defaultServer
	fs := flag.NewFlagSet("aseman", flag.ContinueOnError)
	fs.StringVar(&server, "server", defaultServer, "node API URL")
	fs.StringVar(&token, "token", "", "explicit bearer token")
	fs.StringVar(&jsonBody, "json", "", "raw JSON body")
	fs.SetOutput(io.Discard)
	_ = fs.Parse(args)
	return server, token, jsonBody, fs.Args()
}

func runLogin(args []string) {
	server, _, _, rest := flagsFor(args)
	if len(rest) < 2 {
		fmt.Fprintln(os.Stderr, "usage: aseman login <handle> <password>")
		os.Exit(1)
	}
	resp, err := do(server, "", "auth", "login", map[string]any{
		"account": rest[0], "password": rest[1],
	}, false)
	if err != nil {
		fatal(err)
	}
	var out struct {
		Token      string `json:"token"`
		PrivateKey string `json:"private_key"`
	}
	if err := json.Unmarshal(resp, &out); err != nil || out.Token == "" {
		fatal(fmt.Errorf("login failed: %s", string(resp)))
	}
	dir := filepath.Join(home(), tokenDir)
	_ = os.MkdirAll(dir, 0o700)
	if err := os.WriteFile(filepath.Join(dir, tokenFile), []byte(out.Token), 0o600); err != nil {
		fatal(err)
	}
	if out.PrivateKey != "" {
		if err := os.WriteFile(filepath.Join(dir, keyFile), []byte(out.PrivateKey), 0o600); err != nil {
			fatal(err)
		}
	}
	fmt.Println("logged in; token stored in", filepath.Join(dir, tokenFile))
}

func runLogout() {
	os.Remove(filepath.Join(home(), tokenDir, tokenFile))
	os.Remove(filepath.Join(home(), tokenDir, keyFile))
	fmt.Println("logged out")
}

func runCall(args []string) {
	server, token, jsonBody, rest := flagsFor(args)
	if len(rest) < 1 {
		fmt.Fprintln(os.Stderr, "usage: aseman call <ns>.<action> [k=v ...]")
		os.Exit(1)
	}
	ns, name, ok := splitAction(rest[0])
	if !ok {
		fatal(fmt.Errorf("malformed action %q (expected ns.action)", rest[0]))
	}
	var body map[string]any
	if jsonBody != "" {
		if err := json.Unmarshal([]byte(jsonBody), &body); err != nil {
			fatal(fmt.Errorf("invalid --json: %v", err))
		}
	} else {
		body = parseKV(rest[1:])
	}
	resp, err := do(server, token, ns, name, body, true)
	if err != nil {
		fatal(err)
	}
	fmt.Println(prettify(resp))
}

func runLead(args []string) {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: aseman lead setup|run|questions|answer|routine-create|routine-list [k=v ...]")
		os.Exit(1)
	}
	switch args[0] {
	case "setup":
		// Install the built-in aseman lead agent and add it to every
		// workspace on the node.
		runCall(append([]string{"bots.builtin_aseman"}, args[1:]...))
		runCall(append([]string{"spaces.aseman_ensure"}, args[1:]...))
	case "run":
		// Give the space's lead agent a task: space=<id> body=<task> [room=<id>].
		server, token, _, rest := flagsFor(args[1:])
		resp, err := do(server, token, "bots", "builtin_aseman", map[string]any{}, true)
		if err != nil {
			fatal(err)
		}
		var lead struct {
			BotID string `json:"bot_id"`
		}
		if err := json.Unmarshal(resp, &lead); err != nil || lead.BotID == "" {
			fatal(fmt.Errorf("lead agent unavailable: %s", resp))
		}
		body := parseKV(rest)
		body["bot"] = lead.BotID
		resp, err = do(server, token, "spaces", "ask", body, true)
		if err != nil {
			fatal(err)
		}
		fmt.Println(prettify(resp))
	case "questions":
		// What the space's agents are waiting on: space=<id>.
		runCall(append([]string{"spaces.agent_questions"}, args[1:]...))
	case "answer":
		// Answer one: space=<id> bot=<id> question_id=<id> answer=<text>.
		runCall(append([]string{"spaces.agent_answer"}, args[1:]...))
	case "routine-create", "routine-add":
		// Schedule a delayed or periodic routine in a room.
		runCall(append([]string{"routines.create"}, args[1:]...))
	case "routine-list":
		runCall(append([]string{"routines.list"}, args[1:]...))
	default:
		fmt.Fprintf(os.Stderr, "unknown lead subcommand %q\n", args[0])
		os.Exit(1)
	}
}

func runGet(path string, args []string) {
	server, token, _, _ := flagsFor(args)
	parts := strings.Split(path, "/")
	resp, err := do(server, token, parts[0], parts[1], parseKV(args), true)
	if err != nil {
		fatal(err)
	}
	fmt.Println(prettify(resp))
}

// do performs a call. When useStored is true and no explicit token is given,
// the stored session token is attached. Authenticated requests are signed with
// the stored identity key.
func do(server, token, ns, name string, body map[string]any, useStored bool) ([]byte, error) {
	payload, _ := json.Marshal(body)
	path := "/v1/" + ns + "/" + name
	url := strings.TrimRight(server, "/") + path
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if token == "" && useStored {
		token = storedToken()
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
		if key := storedKey(); key != "" {
			if err := signRequest(req, path, payload, key); err != nil {
				return nil, err
			}
		}
	}
	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		return b, fmt.Errorf("http %d: %s", resp.StatusCode, string(b))
	}
	// Persist a freshly issued identity key (register / oauth responses).
	var parsed map[string]any
	if json.Unmarshal(b, &parsed) == nil {
		if pk, ok := parsed["private_key"].(string); ok && pk != "" {
			dir := filepath.Join(home(), tokenDir)
			_ = os.MkdirAll(dir, 0o700)
			_ = os.WriteFile(filepath.Join(dir, keyFile), []byte(pk), 0o600)
		}
	}
	return b, nil
}

// signRequest attaches the Ed25519 signature headers for a request.
func signRequest(req *http.Request, path string, body []byte, privateKey string) error {
	nonce, err := crypto.NewNonce()
	if err != nil {
		return err
	}
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	bodyHash := sha256Hex(body)
	payload := crypto.RequestPayload(http.MethodPost, path, nonce, ts, bodyHash)
	sig, err := crypto.SignHex(privateKey, payload)
	if err != nil {
		return err
	}
	req.Header.Set(HdrNonce, nonce)
	req.Header.Set(HdrTimestamp, ts)
	req.Header.Set(HdrSignature, sig)
	return nil
}

func sha256Hex(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

const (
	HdrNonce     = "X-Aseman-Nonce"
	HdrTimestamp = "X-Aseman-Timestamp"
	HdrSignature = "X-Aseman-Signature"
)

func storedKey() string {
	b, err := os.ReadFile(filepath.Join(home(), tokenDir, keyFile))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func storedToken() string {
	b, err := os.ReadFile(filepath.Join(home(), tokenDir, tokenFile))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func home() string {
	if h, err := os.UserHomeDir(); err == nil {
		return h
	}
	return "."
}

func splitAction(ref string) (string, string, bool) {
	i := strings.Index(ref, ".")
	if i < 0 {
		return "", "", false
	}
	return ref[:i], ref[i+1:], true
}

func parseKV(args []string) map[string]any {
	out := map[string]any{}
	for _, a := range args {
		i := strings.Index(a, "=")
		if i < 0 {
			continue
		}
		k, v := a[:i], a[i+1:]
		out[k] = coerce(v)
	}
	return out
}

func coerce(s string) any {
	if s == "true" {
		return true
	}
	if s == "false" {
		return false
	}
	// Numbers and JSON structures pass through.
	if strings.HasPrefix(s, "[") || strings.HasPrefix(s, "{") {
		var v any
		if json.Unmarshal([]byte(s), &v) == nil {
			return v
		}
	}
	var n json.Number
	if json.Unmarshal([]byte(s), &n) == nil {
		if i, err := n.Int64(); err == nil {
			return i
		}
		f, err := n.Float64()
		if err == nil {
			return f
		}
	}
	return s
}

func prettify(b []byte) string {
	var v any
	if err := json.Unmarshal(b, &v); err == nil {
		out, _ := json.MarshalIndent(v, "", "  ")
		return string(out)
	}
	return string(b)
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
