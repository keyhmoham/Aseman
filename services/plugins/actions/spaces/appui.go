package spaces

// App UI generation: agents brief OpenCode in the space sandbox; OpenCode
// builds a tested fullstack web app that calls space apps via the preview
// `_aseman/api/call` API; the platform opens it as a DeskWeb card window.

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

const (
	appuiRoot        = "/workspace/appui"
	appuiDefaultPort = 8787
	// OpenCode fullstack builds can take several minutes.
	appuiBuildWait = 12 * time.Minute
)

type appuiReady struct {
	OK      bool   `json:"ok"`
	Tested  bool   `json:"tested"`
	Title   string `json:"title"`
	Port    int    `json:"port"`
	Start   string `json:"start"`
	Dir     string `json:"dir"`
	Summary string `json:"summary"`
	Error   string `json:"error"`
}

func newAppUIID() string {
	var b [6]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// appuiPortFor picks a stable port in 8787..8986 from the App UI id so
// concurrent desk previews do not all fight over the default 8787.
func appuiPortFor(id string) int {
	var h uint32
	for i := 0; i < len(id); i++ {
		h = h*31 + uint32(id[i])
	}
	return appuiDefaultPort + int(h%200)
}

// parseAppuiReadyJSON accepts a READY.json document, or build stdout that
// embeds one (aseman-appui status prints the file after "state: ready").
func parseAppuiReadyJSON(raw string) (appuiReady, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return appuiReady{}, false
	}
	var ready appuiReady
	if json.Unmarshal([]byte(raw), &ready) == nil && ready.OK && ready.Tested && strings.TrimSpace(ready.Start) != "" {
		return ready, true
	}
	// Prefer the last JSON object in the trace (status prints READY last).
	for i := strings.LastIndex(raw, "{"); i >= 0; i = strings.LastIndex(raw[:i], "{") {
		chunk := raw[i:]
		if end := strings.Index(chunk, "}"); end >= 0 {
			chunk = chunk[:end+1]
		}
		ready = appuiReady{}
		if json.Unmarshal([]byte(chunk), &ready) == nil && ready.OK && ready.Tested && strings.TrimSpace(ready.Start) != "" {
			return ready, true
		}
	}
	return appuiReady{}, false
}

func (s *Service) sandboxWriteBytes(ctx context.Context, spaceID identity.ID, dest string, data []byte) error {
	cmd := fmt.Sprintf(`set -eu
mkdir -p %s
printf '%%s' %s | base64 -d > %s
`, shellFilePath(path.Dir(dest)), shellFilePath(base64.StdEncoding.EncodeToString(data)), shellFilePath(dest))
	out, err := s.SandboxExec(ctx, spaceID, cmd)
	if err != nil {
		return err
	}
	if !strings.HasPrefix(out, "exit=0\n") {
		return errs.New(errs.CodeUnavailable, "sandbox write failed: "+out)
	}
	return nil
}

func (s *Service) sandboxReadText(ctx context.Context, spaceID identity.ID, p string) (string, error) {
	data, err := s.sandboxReadFile(ctx, spaceID, p)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// appCatalogJSON lists space apps an on-demand UI may call (bot id, name, microtools).
func (s *Service) appCatalogJSON(ctx context.Context, spaceID, roomID identity.ID) ([]byte, error) {
	tools, err := s.SpaceTools(ctx, spaceID, roomID)
	if err != nil {
		return nil, err
	}
	type cmd struct {
		Name        string `json:"name"`
		Description string `json:"description,omitempty"`
	}
	type app struct {
		BotID       string `json:"bot_id,omitempty"`
		Name        string `json:"name"`
		Description string `json:"description,omitempty"`
		Microtools  []cmd  `json:"microtools,omitempty"`
	}
	var apps []app
	for _, t := range tools {
		if t.BotID == "" || strings.HasPrefix(t.Name, "sandbox") {
			continue
		}
		// Skip platform builtins (no bot) already filtered; include tool backends.
		if t.Kind != "" && t.Kind != "tool" {
			continue
		}
		a := app{BotID: t.BotID, Name: t.Name, Description: t.Description}
		for _, c := range t.Commands {
			a.Microtools = append(a.Microtools, cmd{Name: c.Name, Description: c.Description})
		}
		apps = append(apps, a)
	}
	return json.Marshal(map[string]any{
		"apps": apps,
		"call": map[string]any{
			"how": "From the preview page, POST relative _aseman/api/call with {tool, microtool, args}. List with _aseman/api/tools. " +
				"The response {result} is already unwrapped from MCP: often a plain text/markdown string (Exa, Hugging Face, …), " +
				"sometimes a JSON object. Never invent REST shapes like {results:[{title,url}]} or {items:[…]} — parse or render the actual result (probe in tests with fixtures that match text/markdown).",
			"path": "_aseman/api/call",
		},
	})
}

// appuiCreateTool implements appui_create: brief → OpenCode build+test → proxy DeskWeb card.
func (s *Service) appuiCreateTool(ctx context.Context, spaceID, roomID identity.ID, agentName, argsJSON string) (string, error) {
	var in struct {
		Brief   string       `json:"brief"`
		Title   string       `json:"title"`
		Apps    []string     `json:"apps"`
		Tool    string       `json:"tool"`
		Dir     string       `json:"dir"`
		Port    int          `json:"port"`
		ID      string       `json:"id"`
		X       *float64     `json:"x"`
		Y       *float64     `json:"y"`
		W       *float64     `json:"w"`
		H       *float64     `json:"h"`
		Compact *DeskCompact `json:"compact"`
		Room    string       `json:"room"`
		Show    *bool        `json:"show"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument("appui_create arguments must be a JSON object")
	}
	brief := strings.TrimSpace(in.Brief)
	if brief == "" {
		return "", errs.InvalidArgument("appui_create needs brief (what to build)")
	}
	target, err := deskRoom(roomID, in.Room)
	if err != nil {
		return "", err
	}
	id := strings.TrimSpace(in.ID)
	if id == "" {
		id = newAppUIID()
	}
	dir := strings.TrimSpace(in.Dir)
	if dir == "" {
		dir = appuiRoot + "/" + id
	}
	if !strings.HasPrefix(dir, "/workspace/") {
		return "", errs.InvalidArgument("dir must be under /workspace/")
	}
	port := in.Port
	if port == 0 {
		port = appuiPortFor(id)
	}
	if port < 1 || port > 65535 {
		return "", errs.InvalidArgument("port must be in 1..65535")
	}
	title := strings.TrimSpace(in.Title)
	if title == "" {
		title = "App"
	}

	// App UI builds routinely exceed the short deadlines that wrap agent / Code
	// Mode tool calls. Keep values (actor, run id, TurnLLM, stop) but detach
	// the clock so READY.json can still be read after a long OpenCode build.
	opCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), appuiBuildWait)
	defer cancel()

	catalog, err := s.appCatalogJSON(opCtx, spaceID, target)
	if err != nil {
		return "", err
	}
	if len(in.Apps) > 0 {
		// Narrow catalog to requested app names/ids when the agent lists them.
		var raw map[string]any
		_ = json.Unmarshal(catalog, &raw)
		want := map[string]bool{}
		for _, a := range in.Apps {
			want[strings.ToLower(strings.TrimSpace(a))] = true
		}
		if want[strings.ToLower(strings.TrimSpace(in.Tool))] {
			// ok
		} else if t := strings.TrimSpace(in.Tool); t != "" {
			want[strings.ToLower(t)] = true
		}
		filtered := []any{}
		if apps, _ := raw["apps"].([]any); apps != nil {
			for _, item := range apps {
				m, _ := item.(map[string]any)
				name, _ := m["name"].(string)
				bot, _ := m["bot_id"].(string)
				if want[strings.ToLower(name)] || want[strings.ToLower(bot)] {
					filtered = append(filtered, item)
				}
			}
		}
		if len(filtered) > 0 {
			raw["apps"] = filtered
			catalog, _ = json.Marshal(raw)
		}
	}

	briefPath := dir + "/.aseman-brief.md"
	appsPath := dir + "/.aseman-apps.json"
	if err := s.sandboxWriteBytes(opCtx, spaceID, briefPath, []byte(brief+"\n")); err != nil {
		return "", err
	}
	if err := s.sandboxWriteBytes(opCtx, spaceID, appsPath, catalog); err != nil {
		return "", err
	}
	// Point OpenCode at this turn's metered LLM gateway (same backbone + billing
	// as the agent). CreateBot Env alone cannot carry the turn token.
	if err := s.ensureOpenCodeAuth(opCtx, spaceID); err != nil {
		return "", err
	}

	buildCmd := fmt.Sprintf(
		`. /etc/opencode/env.sh 2>/dev/null || true; unset OPENCODE_API_KEY; export OPENCODE_MODEL=${OPENCODE_MODEL:-aseman/default}; aseman-appui build --dir %s --brief-file %s --apps-file %s --title %s --port %d`,
		shellQuote(dir), shellQuote(briefPath), shellQuote(appsPath), shellQuote(title), port,
	)
	out, err := s.SandboxExec(opCtx, spaceID, buildCmd)
	// Prefer READY.json on disk; fall back to parsing build stdout (status prints it).
	readyRaw, readErr := s.sandboxReadText(opCtx, spaceID, dir+"/READY.json")
	ready, ok := parseAppuiReadyJSON(readyRaw)
	if !ok {
		ready, ok = parseAppuiReadyJSON(out)
	}
	if !ok {
		if readErr != nil && err != nil {
			return "", errs.New(errs.CodeUnavailable, "appui build failed: "+clipTrace(out, 4000))
		}
		msg := ready.Error
		if msg == "" {
			msg = "OpenCode did not produce a tested READY.json"
		}
		return "", errs.Conflict("appui not ready: "+msg+"\n"+clipTrace(out, 2000))
	}
	if ready.Port > 0 {
		port = ready.Port
	}
	if ready.Title != "" {
		title = ready.Title
	}
	start := strings.TrimSpace(ready.Start)
	// Ensure start runs from the project directory.
	if !strings.Contains(start, dir) {
		start = "cd " + shellQuote(dir) + " && " + start
	}

	show := true
	if in.Show != nil {
		show = *in.Show
	}
	// Open on the desk of the room where the person asked. Explicit room=home
	// targets the hall ("My trading desk"); an explicit room id uses that room.
	deskTarget := ""
	arrangeRoom := identity.ID{}
	switch r := strings.TrimSpace(in.Room); {
	case r == "home":
		deskTarget = "home"
	case !target.IsZero():
		deskTarget = target.String()
		arrangeRoom = target
	case !roomID.IsZero():
		deskTarget = roomID.String()
		arrangeRoom = roomID
	default:
		deskTarget = "home"
	}
	proxyArgs := map[string]any{
		"port":  port,
		"title": title,
		"start": start,
		"show":  show,
		"tool":  strings.TrimSpace(in.Tool),
		"room":  deskTarget,
	}
	rawArgs, _ := json.Marshal(proxyArgs)
	proxyOut, err := s.proxyCreateTool(opCtx, spaceID, agentName, string(rawArgs))
	if err != nil {
		return "", err
	}

	// Optional desk placement after open.
	if in.X != nil || in.Y != nil || in.W != nil || in.H != nil || in.Compact != nil {
		// Best-effort: arrange the most recently opened matching title window.
		_ = s.appuiArrangeHint(ctx, spaceID, arrangeRoom, agentName, in.X, in.Y, in.W, in.H)
	}

	result := map[string]any{
		"id":      id,
		"dir":     dir,
		"title":   title,
		"port":    port,
		"start":   start,
		"summary": ready.Summary,
		"tested":  true,
		"proxy":   proxyOut,
	}
	b, _ := json.Marshal(result)
	return string(b), nil
}

func (s *Service) appuiArrangeHint(ctx context.Context, spaceID, roomID identity.ID, agentName string, x, y, w, h *float64) error {
	d, err := s.Desk(ctx, spaceID, roomID)
	if err != nil || len(d.Windows) == 0 {
		return err
	}
	last := d.Windows[len(d.Windows)-1]
	win := map[string]any{"id": last.ID}
	if x != nil {
		win["x"] = *x
	}
	if y != nil {
		win["y"] = *y
	}
	if w != nil {
		win["w"] = *w
	}
	if h != nil {
		win["h"] = *h
	}
	body, _ := json.Marshal(map[string]any{"windows": []any{win}})
	_, err = s.deskArrangeTool(ctx, spaceID, roomID, agentName, string(body))
	return err
}

// ensureOpenCodeAuth points the sandbox OpenCode at this agent turn's metered
// LLM gateway (same /deepagents/v1/llm backbone agents use). Completions are
// gated and billed on the turn via serveChat → meter → billAgentTurn.
func (s *Service) ensureOpenCodeAuth(ctx context.Context, spaceID identity.ID) error {
	llm := vmm.TurnLLMFrom(ctx)
	if strings.TrimSpace(llm.Token) == "" || strings.TrimSpace(llm.BaseURL) == "" {
		return errs.New(errs.CodeUnavailable, "OpenCode needs the agent turn's LLM gateway (call appui_create / opencode_run during a turn)")
	}
	model := strings.TrimSpace(llm.Model)
	if model == "" {
		model = "aseman/default"
	}
	if override := strings.TrimSpace(os.Getenv("OPENCODE_MODEL")); override != "" && override != "free" {
		model = override
	}
	baseURL := strings.TrimRight(strings.TrimSpace(llm.BaseURL), "/")
	envBody := strings.Join([]string{
		"export ASEMAN_LLM_BASE_URL=" + shellQuote(baseURL),
		"export ASEMAN_LLM_API_KEY=" + shellQuote(llm.Token),
		"export OPENCODE_MODEL=" + shellQuote(model),
		// Prefer Aseman backbone; ignore leftover Zen free-tier keys.
		"unset OPENCODE_API_KEY 2>/dev/null || true",
	}, "\n") + "\n"
	cfg, err := openCodeAsemanConfig(baseURL, model)
	if err != nil {
		return err
	}
	authJSON := fmt.Sprintf(`{"aseman":{"type":"api","key":%s}}`, mustJSONString(llm.Token))
	cmd := fmt.Sprintf(`set -eu
mkdir -p /etc/opencode /root/.config/opencode /root/.local/share/opencode
printf '%%s' %s > /etc/opencode/env.sh
printf '%%s' %s > /etc/opencode/opencode.json
printf '%%s' %s > /root/.config/opencode/opencode.json
printf '%%s' %s > /root/.local/share/opencode/auth.json
grep -q '/etc/opencode/env.sh' /etc/profile 2>/dev/null || echo '. /etc/opencode/env.sh' >> /etc/profile
`, shellQuote(envBody), shellQuote(string(cfg)), shellQuote(string(cfg)), shellQuote(authJSON))
	_, err = s.SandboxExec(ctx, spaceID, cmd)
	return err
}

// openCodeAsemanConfig is the OpenCode provider file that targets Aseman's
// OpenAI-compatible, metered LLM proxy for the current turn.
func openCodeAsemanConfig(baseURL, model string) ([]byte, error) {
	// model is "aseman/default"; OpenCode splits provider/model.
	modelID := "default"
	if i := strings.LastIndex(model, "/"); i >= 0 && i+1 < len(model) {
		modelID = model[i+1:]
	}
	doc := map[string]any{
		"$schema": "https://opencode.ai/config.json",
		"model":   model,
		"provider": map[string]any{
			"aseman": map[string]any{
				"npm":  "@ai-sdk/openai-compatible",
				"name": "Aseman",
				"options": map[string]any{
					"baseURL": baseURL,
					"apiKey":  "{env:ASEMAN_LLM_API_KEY}",
				},
				"models": map[string]any{
					modelID: map[string]any{"name": "Aseman agent model"},
				},
			},
		},
		"permission": map[string]any{"*": "allow"},
	}
	return json.MarshalIndent(doc, "", "  ")
}

func mustJSONString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// opencodeRunTool distributes a coding/programming task to OpenCode in the sandbox.
func (s *Service) opencodeRunTool(ctx context.Context, spaceID identity.ID, argsJSON string) (string, error) {
	var in struct {
		Message string `json:"message"`
		Dir     string `json:"dir"`
		Model   string `json:"model"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument("opencode_run args: {\"message\":\"…\"}")
	}
	msg := strings.TrimSpace(in.Message)
	if msg == "" {
		return "", errs.InvalidArgument("opencode_run needs message")
	}
	dir := strings.TrimSpace(in.Dir)
	if dir == "" {
		dir = appuiRoot + "/tasks/" + newAppUIID()
	}
	if !strings.HasPrefix(dir, "/workspace/") {
		return "", errs.InvalidArgument("dir must be under /workspace/")
	}
	if err := s.ensureOpenCodeAuth(ctx, spaceID); err != nil {
		return "", err
	}
	cmd := fmt.Sprintf(`. /etc/opencode/env.sh 2>/dev/null || true; unset OPENCODE_API_KEY; aseman-appui run --dir %s --message %s`, shellQuote(dir), shellQuote(msg))
	if m := strings.TrimSpace(in.Model); m != "" && m != "free" && !strings.HasPrefix(m, "opencode/") {
		cmd = "OPENCODE_MODEL=" + shellQuote(m) + " " + cmd
	}
	runCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), appuiBuildWait)
	defer cancel()
	out, err := s.SandboxExec(runCtx, spaceID, cmd)
	if err != nil {
		return clipTrace(out, 8000), err
	}
	status, _ := s.sandboxReadText(ctx, spaceID, dir+"/STATUS.json")
	ready, _ := s.sandboxReadText(ctx, spaceID, dir+"/READY.json")
	res := map[string]any{"dir": dir, "output": clipTrace(out, 4000)}
	if status != "" {
		var st any
		if json.Unmarshal([]byte(status), &st) == nil {
			res["status"] = st
		} else {
			res["status_raw"] = status
		}
	}
	if ready != "" {
		var rd any
		if json.Unmarshal([]byte(ready), &rd) == nil {
			res["ready"] = rd
		}
	}
	b, _ := json.Marshal(res)
	return string(b), nil
}

func (s *Service) opencodeStatusTool(ctx context.Context, spaceID identity.ID, argsJSON string) (string, error) {
	var in struct {
		Dir string `json:"dir"`
	}
	_ = json.Unmarshal([]byte(argsJSON), &in)
	dir := strings.TrimSpace(in.Dir)
	if dir == "" {
		dir = appuiRoot
	}
	out, err := s.SandboxExec(ctx, spaceID, "aseman-appui status "+shellQuote(dir))
	if err != nil {
		return out, err
	}
	return out, nil
}

func (s *Service) opencodeModelsTool(ctx context.Context, spaceID identity.ID) (string, error) {
	out, err := s.SandboxExec(ctx, spaceID, "aseman-appui models")
	if err != nil {
		return out, err
	}
	return out, nil
}

// openCodeBuiltinApp is listed beside space apps so agents see OpenCode as a
// builtin coding app with microtool-style platform commands.
func openCodeBuiltinApp() vmm.Tool {
	str := func(d string) map[string]any { return map[string]any{"type": "string", "description": d} }
	obj := func(props map[string]any, req ...string) map[string]any {
		s := map[string]any{"type": "object", "properties": props}
		if len(req) > 0 {
			s["required"] = req
		}
		return s
	}
	return vmm.Tool{
		Name:        "opencode",
		Kind:        "tool",
		Description: "Built-in OpenCode coding agent in the space sandbox. Uses the same metered Aseman LLM gateway as agents (usage billed on the turn). Distribute programming tasks with opencode_run; build interactive fullstack App UIs with appui_create (Material 3 Expressive / @material/web by default; Aseman light/dark+accent theming; mix OpenUI agent islands with programmed UI via _aseman/kit/openui and _aseman/api/ask); check progress with opencode_status; list models with opencode_models. Generated apps call space apps via _aseman/api/call and open as DeskWeb card windows.",
		Commands: []vmm.ToolCommand{
			{Name: "run", Description: "Send a coding task to OpenCode (platform: opencode_run).", Schema: obj(map[string]any{"message": str("Task"), "dir": str("Optional /workspace/… dir"), "model": str("Optional model; default aseman/default")}, "message")},
			{Name: "status", Description: "Status of an OpenCode / App UI job (platform: opencode_status).", Schema: obj(map[string]any{"dir": str("Project dir under /workspace")})},
			{Name: "models", Description: "Show Aseman LLM backbone / model (platform: opencode_models).", Schema: obj(map[string]any{})},
			{Name: "build", Description: "Build a tested fullstack App UI from a brief (platform: appui_create; M3 Expressive UI by default).", Schema: obj(map[string]any{"brief": str("What to build; omit UI framework to get Material 3 Expressive"), "title": str("Window title"), "apps": map[string]any{"type": "array", "items": map[string]any{"type": "string"}}, "tool": str("Optional dock tool bot id"), "port": map[string]any{"type": "integer"}}, "brief")},
		},
	}
}
