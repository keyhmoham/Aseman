package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

const workflowUsage = `aseman workflow — the developer API's workflow installer (docs/WORKFLOWS.md)

Usage:
  aseman workflow validate <file.json>
  aseman workflow plan     <file.json> [input=value ...]
  aseman workflow run      <file.json> [input=value ...]
  aseman workflow runs
  aseman workflow get      <run-id>
  aseman workflow cancel   <run-id>
  aseman workflow schema   > workflow.schema.json
  aseman workflow reference

Flags:
  --key <dk_live_…>    use the developer API with this key (or $ASEMAN_DEVELOPER_KEY);
                       without one, the signed-in session (aseman login) is used
  --api <url>          the developer API (or $ASEMAN_DEVELOPER_API_URL; default <server>/dev/v1)
  --server <url>       the node, for the signed-in session (default http://localhost:8080)
  --org <id>           the console's organization (default personal)
  --inputs <file>      inputs as a JSON object (input=value pairs are added on top)
  --secret NAME=VALUE  a secret (repeatable); a declared secret not given is read
                       from the environment variable of the same name
  --assets <dir>[=<prefix>]  add every file under dir to the document's assets,
                       under prefix (repeatable), e.g. --assets ./app=app/
  --resume <run-id>    reuse what that run finished
  --async              answer at once; with --follow (default) the run is followed
  --no-follow          do not follow a run that is still going
  --json               print the raw answer
`

type multi []string

func (m *multi) String() string     { return strings.Join(*m, ",") }
func (m *multi) Set(v string) error { *m = append(*m, v); return nil }

type wfClient struct {
	key, api, server, token, org string
}

func runWorkflow(args []string) {
	if len(args) == 0 || args[0] == "help" || args[0] == "-h" {
		fmt.Print(workflowUsage)
		return
	}
	sub := args[0]
	fs := flag.NewFlagSet("workflow", flag.ExitOnError)
	c := &wfClient{}
	var inputsFile, resume string
	var secrets, assetDirs multi
	var async, noFollow, raw bool
	fs.StringVar(&c.key, "key", os.Getenv("ASEMAN_DEVELOPER_KEY"), "")
	fs.StringVar(&c.api, "api", os.Getenv("ASEMAN_DEVELOPER_API_URL"), "")
	fs.StringVar(&c.server, "server", defaultServer, "")
	fs.StringVar(&c.token, "token", "", "")
	fs.StringVar(&c.org, "org", "", "")
	fs.StringVar(&inputsFile, "inputs", "", "")
	fs.StringVar(&resume, "resume", "", "")
	fs.Var(&secrets, "secret", "")
	fs.Var(&assetDirs, "assets", "")
	fs.BoolVar(&async, "async", false, "")
	fs.BoolVar(&noFollow, "no-follow", false, "")
	fs.BoolVar(&raw, "json", false, "")
	fs.Usage = func() { fmt.Fprint(os.Stderr, workflowUsage) }
	_ = fs.Parse(reorder(args[1:]))
	rest := fs.Args()
	if c.api == "" {
		c.api = strings.TrimRight(c.server, "/") + "/dev/v1"
	}

	need := func(n int, what string) {
		if len(rest) < n {
			fatal(fmt.Errorf("aseman workflow %s needs %s", sub, what))
		}
	}
	switch sub {
	case "validate", "plan", "run":
		need(1, "a workflow file")
		doc := loadDocument(rest[0], assetDirs)
		body := map[string]any{"workflow": doc}
		if sub != "validate" {
			inputs := map[string]any{}
			if inputsFile != "" {
				b, err := os.ReadFile(inputsFile)
				if err != nil {
					fatal(err)
				}
				if err := json.Unmarshal(b, &inputs); err != nil {
					fatal(fmt.Errorf("--inputs: %v", err))
				}
			}
			for k, v := range parseKV(rest[1:]) {
				inputs[k] = v
			}
			body["inputs"] = inputs
			body["secrets"] = collectSecrets(doc, secrets)
		}
		if sub == "run" {
			body["async"] = async
			if resume != "" {
				body["resume_from"] = resume
			}
		}
		out := c.call(sub, "", body)
		if sub == "validate" {
			printValidation(out, raw)
			return
		}
		if !noFollow && out["status"] == "running" {
			out = c.follow(out["id"].(string), raw)
		}
		printRun(out, raw)
	case "runs":
		out := c.call("runs", "", nil)
		if raw {
			fmt.Println(prettyJSON(out))
			return
		}
		list, _ := out["data"].([]any)
		if list == nil {
			list, _ = out["runs"].([]any)
		}
		for _, r := range list {
			m, _ := r.(map[string]any)
			fmt.Printf("%-34s %-12s %-5s %-24s %s\n", m["id"], m["status"], m["mode"], m["name"], m["started_at"])
		}
	case "get":
		need(1, "a run id")
		printRun(c.call("get", rest[0], nil), raw)
	case "cancel":
		need(1, "a run id")
		fmt.Println(prettyJSON(c.call("cancel", rest[0], nil)))
	case "schema", "reference":
		fmt.Println(prettyJSON(c.call(sub, "", nil)))
	default:
		fmt.Fprintf(os.Stderr, "unknown workflow command %q\n\n%s", sub, workflowUsage)
		os.Exit(1)
	}
}

// reorder puts flags before positional arguments, so they can come anywhere.
func reorder(args []string) []string {
	var flags, pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if strings.HasPrefix(a, "-") {
			flags = append(flags, a)
			name := strings.TrimLeft(a, "-")
			boolean := name == "async" || name == "no-follow" || name == "json"
			if !strings.Contains(a, "=") && !boolean && i+1 < len(args) {
				flags = append(flags, args[i+1])
				i++
			}
			continue
		}
		pos = append(pos, a)
	}
	return append(flags, pos...)
}

// loadDocument reads the workflow and folds asset folders into it.
func loadDocument(file string, dirs []string) map[string]any {
	b, err := os.ReadFile(file)
	if err != nil {
		fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		fatal(fmt.Errorf("%s is not JSON: %v", file, err))
	}
	if len(dirs) == 0 {
		return doc
	}
	assets, _ := doc["assets"].(map[string]any)
	if assets == nil {
		assets = map[string]any{}
	}
	for _, spec := range dirs {
		dir, prefix, _ := strings.Cut(spec, "=")
		n := 0
		err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				switch d.Name() {
				case ".git", "node_modules", "__pycache__", ".venv", "dist", "build":
					if p != dir {
						return filepath.SkipDir
					}
				}
				return nil
			}
			rel, _ := filepath.Rel(dir, p)
			data, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			entry := map[string]any{}
			if utf8.Valid(data) && !bytes.ContainsRune(data, 0) {
				entry["content"] = string(data)
			} else {
				entry["base64"] = base64.StdEncoding.EncodeToString(data)
			}
			if info, err := d.Info(); err == nil && info.Mode()&0o111 != 0 {
				entry["mode"] = "0755"
			}
			assets[prefix+filepath.ToSlash(rel)] = entry
			n++
			return nil
		})
		if err != nil {
			fatal(fmt.Errorf("--assets %s: %v", dir, err))
		}
		fmt.Fprintf(os.Stderr, "added %d file(s) from %s as assets %s*\n", n, dir, prefix)
	}
	doc["assets"] = assets
	return doc
}

// collectSecrets takes --secret values, then the environment for the rest
// of the secrets the document declares.
func collectSecrets(doc map[string]any, given []string) map[string]string {
	out := map[string]string{}
	for _, s := range given {
		k, v, ok := strings.Cut(s, "=")
		if !ok {
			fatal(fmt.Errorf("--secret %q: use NAME=VALUE", s))
		}
		out[k] = v
	}
	var names []string
	switch x := doc["secrets"].(type) {
	case []any:
		for _, e := range x {
			switch s := e.(type) {
			case string:
				names = append(names, s)
			case map[string]any:
				if n, ok := s["name"].(string); ok {
					names = append(names, n)
				}
			}
		}
	case map[string]any:
		for n := range x {
			names = append(names, n)
		}
	}
	for _, n := range names {
		if _, ok := out[n]; !ok {
			if v, ok := os.LookupEnv(n); ok {
				out[n] = v
			}
		}
	}
	return out
}

// call reaches the workflow API through the key's door or the session's.
func (c *wfClient) call(op, id string, body map[string]any) map[string]any {
	var b []byte
	var err error
	if c.key != "" {
		method, path := http.MethodPost, ""
		switch op {
		case "validate":
			path = "/workflows/validate"
		case "plan":
			path = "/workflows/plan"
		case "run":
			path = "/workflows/runs"
		case "runs":
			method, path = http.MethodGet, "/workflows/runs"
		case "get":
			method, path = http.MethodGet, "/workflows/runs/"+id
		case "cancel":
			path = "/workflows/runs/" + id + "/cancel"
		case "schema", "reference":
			method, path = http.MethodGet, "/workflows/"+op
		}
		b, err = c.keyRequest(method, path, body)
	} else {
		action := map[string]string{"validate": "workflow_validate", "plan": "workflow_plan", "run": "workflow_run", "runs": "workflow_runs",
			"get": "workflow_run_get", "cancel": "workflow_run_cancel", "schema": "workflow_schema", "reference": "workflow_reference"}[op]
		if body == nil {
			body = map[string]any{}
		}
		if id != "" {
			body["id"] = id
		}
		if c.org != "" {
			body["org"] = c.org
		}
		b, err = do(c.server, c.token, "developer", action, body, true)
	}
	if err != nil {
		fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(b, &out); err != nil {
		fatal(fmt.Errorf("unexpected answer: %s", b))
	}
	return out
}

func (c *wfClient) keyRequest(method, path string, body map[string]any) ([]byte, error) {
	var reader io.Reader
	if body != nil {
		payload, _ := json.Marshal(body)
		reader = bytes.NewReader(payload)
	}
	req, err := http.NewRequest(method, strings.TrimRight(c.api, "/")+path, reader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		var e struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(b, &e) == nil && e.Error.Message != "" {
			return nil, fmt.Errorf("http %d: %s", resp.StatusCode, e.Error.Message)
		}
		return nil, fmt.Errorf("http %d: %s", resp.StatusCode, b)
	}
	return b, nil
}

// follow polls a run, printing its log as it grows, until it is over.
func (c *wfClient) follow(id string, quiet bool) map[string]any {
	seen := 0
	if !quiet {
		fmt.Fprintf(os.Stderr, "run %s is going; following (Ctrl-C stops following, not the run)\n", id)
	}
	for {
		out := c.call("get", id, nil)
		if rep, ok := out["report"].(map[string]any); ok && !quiet {
			events, _ := rep["events"].([]any)
			for _, e := range events[min(seen, len(events)):] {
				m, _ := e.(map[string]any)
				fmt.Fprintf(os.Stderr, "  %-7s %-28s %s\n", m["level"], m["path"], m["message"])
			}
			seen = len(events)
		}
		if out["status"] != "running" && out["status"] != "cancelling" {
			return out
		}
		time.Sleep(2 * time.Second)
	}
}

func printValidation(out map[string]any, raw bool) {
	if raw {
		fmt.Println(prettyJSON(out))
	} else {
		issues, _ := out["issues"].([]any)
		for _, i := range issues {
			m, _ := i.(map[string]any)
			fmt.Printf("%-8s %s: %s\n", m["severity"], m["path"], m["message"])
		}
		if out["valid"] == true {
			fmt.Printf("valid: %v, %v step(s), %v asset(s)\n", out["name"], out["steps"], out["assets"])
		}
	}
	if out["valid"] != true {
		os.Exit(1)
	}
}

func printRun(out map[string]any, raw bool) {
	if raw {
		fmt.Println(prettyJSON(out))
	} else {
		rep, _ := out["report"].(map[string]any)
		fmt.Printf("%s %s — %s\n", out["name"], out["id"], out["status"])
		if rep != nil {
			steps, _ := rep["steps"].([]any)
			for _, s := range steps {
				m, _ := s.(map[string]any)
				op := ""
				if v, ok := m["operation"].(string); ok {
					op = " (" + v + ")"
				}
				line := fmt.Sprintf("  %-10s %-32s %s%s", m["status"], m["path"], m["action"], op)
				if e, ok := m["error"].(string); ok && e != "" {
					line += " — " + e
				}
				fmt.Println(line)
			}
			if outputs, ok := rep["outputs"].(map[string]any); ok && len(outputs) > 0 {
				keys := make([]string, 0, len(outputs))
				for k := range outputs {
					keys = append(keys, k)
				}
				sort.Strings(keys)
				fmt.Println("outputs:")
				for _, k := range keys {
					v, _ := json.Marshal(outputs[k])
					fmt.Printf("  %s = %s\n", k, v)
				}
			}
		}
		if e, ok := out["error"].(string); ok && e != "" {
			fmt.Println("error:", e)
		}
	}
	switch out["status"] {
	case "succeeded", "planned", "running":
	default:
		os.Exit(1)
	}
}

func prettyJSON(v any) string {
	b, _ := json.MarshalIndent(v, "", "  ")
	return string(b)
}
