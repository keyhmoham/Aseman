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
	"regexp"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

const (
	appuiRoot        = "/workspace/appui"
	appuiDefaultPort = 8787
	// OpenCode fullstack builds can take several minutes, and a build that
	// fails its checks gets repair rounds (aseman-appui build).
	appuiBuildWait = 30 * time.Minute
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
	// UI is the frontend built: "elpian" (an Elpian program the client runs
	// natively) or "web"; Elpian is that program's path in the app.
	UI     string `json:"ui"`
	Elpian string `json:"elpian"`
	// Widget is a web app's phone widget program (an Elpian app's program
	// draws its own).
	Widget string `json:"widget"`
}

// App UI frontends. Elpian is the default; web only when the person asked
// for web technology.
const (
	appuiElpian = "elpian"
	appuiWeb    = "web"
)

// appuiFrontend picks an App UI's frontend: the one asked for, else what an
// existing app was built with, else Elpian.
func appuiFrontend(asked, existing string) (string, error) {
	switch ui := strings.ToLower(strings.TrimSpace(asked)); ui {
	case appuiElpian, appuiWeb:
		return ui, nil
	case "":
		if existing == appuiWeb {
			return appuiWeb, nil
		}
		return appuiElpian, nil
	default:
		return "", errs.InvalidArgument(`ui is "elpian" (the default: a native Elpian frontend) or "web" (only when the person asked for web technology)`)
	}
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

// appuiCatalog is what OpenCode is told about the space it builds for
// (APPS.json): the apps whose microtools the software may call, with their
// argument schemas, and the agents it may ask, so it wires real names and
// real argument shapes instead of guessing. [apps] / [agents] narrow the
// lists to what the brief names (names or bot ids); empty keeps them all.
func (s *Service) appuiCatalog(ctx context.Context, spaceID, roomID identity.ID, apps, agents []string) ([]byte, error) {
	tools, err := s.SpaceTools(ctx, spaceID, roomID)
	if err != nil {
		return nil, err
	}
	wanted := func(list []string, name, id string) bool {
		if len(list) == 0 {
			return true
		}
		for _, w := range list {
			w = strings.TrimSpace(w)
			if strings.EqualFold(w, name) || w == id {
				return true
			}
		}
		return false
	}
	type microtool struct {
		Name        string         `json:"name"`
		Description string         `json:"description,omitempty"`
		Args        map[string]any `json:"args_schema,omitempty"`
	}
	type app struct {
		BotID       string      `json:"bot_id,omitempty"`
		Name        string      `json:"name"`
		Description string      `json:"description,omitempty"`
		Microtools  []microtool `json:"microtools,omitempty"`
	}
	type agent struct {
		ID          string `json:"id"`
		Name        string `json:"name"`
		Description string `json:"description,omitempty"`
	}
	appList := []app{}
	for _, t := range tools {
		// Platform builtins have no bot; the sandbox is a computer, not an app.
		if t.BotID == "" || strings.HasPrefix(t.Name, "sandbox") || (t.Kind != "" && t.Kind != "tool") {
			continue
		}
		if !wanted(apps, t.Name, t.BotID) {
			continue
		}
		a := app{BotID: t.BotID, Name: t.Name, Description: t.Description}
		for _, c := range t.Commands {
			a.Microtools = append(a.Microtools, microtool{Name: c.Name, Description: c.Description, Args: c.Schema})
		}
		appList = append(appList, a)
	}
	agentList := []agent{}
	var mems []membership.Membership
	_ = s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "role": string(membership.RoleBot)},
	}, &mems)
	seen := map[string]bool{}
	for i := range mems {
		rec, err := s.botForMember(ctx, mems[i].MemberID)
		if err != nil || rec.Kind != bot.KindAgent || seen[rec.ID.String()] {
			continue
		}
		seen[rec.ID.String()] = true
		if !wanted(agents, rec.Name, rec.ID.String()) {
			continue
		}
		agentList = append(agentList, agent{ID: rec.ID.String(), Name: rec.Name, Description: s.toolDescription(ctx, rec)})
	}
	sp := map[string]any{"id": spaceID.String()}
	if rec, err := s.GetSpace(ctx, spaceID); err == nil {
		sp["name"] = rec.Name
	}
	return json.MarshalIndent(map[string]any{
		"space":  sp,
		"apps":   appList,
		"agents": agentList,
		"api":    "See ASEMAN_API.md: apps via POST _aseman/api/call {tool, microtool, args}; agents via POST _aseman/api/ask {agent, prompt}. vendor/aseman-sdk/aseman.js wraps both.",
	}, "", "  ")
}

// appuiCreateTool implements appui_create: brief → OpenCode build+test → proxy DeskWeb card.
func (s *Service) appuiCreateTool(ctx context.Context, spaceID, roomID identity.ID, agentName, argsJSON string) (string, error) {
	var in struct {
		Brief   string       `json:"brief"`
		Title   string       `json:"title"`
		Apps    []string     `json:"apps"`
		Agents  []string     `json:"agents"`
		UI      string       `json:"ui"`
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

	wantApps := in.Apps
	if t := strings.TrimSpace(in.Tool); t != "" && len(wantApps) > 0 {
		wantApps = append(wantApps, t)
	}
	catalog, err := s.appuiCatalog(opCtx, spaceID, target, wantApps, in.Agents)
	if err != nil {
		return "", err
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
	// The app's server uses the space's agents and apps too: with the token
	// of the person using it (sent with each request), or, for work nobody
	// is in front of, with the app's key, which acts for and bills the person
	// who asked for the app.
	hasKey := false
	if owner := appOwner(ctx); !owner.IsZero() {
		key, kerr := s.IssueAppKey(opCtx, spaceID, target, owner, dir, title)
		if kerr != nil {
			return "", kerr
		}
		if err := s.writeAppServerEnv(opCtx, spaceID, dir, key); err != nil {
			return "", err
		}
		hasKey = true
	} else if err := s.writeAppServerEnv(opCtx, spaceID, dir, ""); err != nil {
		return "", err
	}

	// A project that was built before is changed in place (a follow-up:
	// "add a filter", "fix the chart"), not rebuilt from nothing.
	mode, existingUI := "new", ""
	if job, jerr := s.sandboxReadText(opCtx, spaceID, dir+"/JOB.json"); jerr == nil && strings.TrimSpace(job) != "" {
		mode = "update"
		var j struct {
			UI string `json:"ui"`
		}
		if json.Unmarshal([]byte(job), &j) == nil {
			existingUI = j.UI
		}
		if existingUI == "" {
			existingUI = appuiWeb // built before Elpian became the default
		}
	}
	ui, err := appuiFrontend(in.UI, existingUI)
	if err != nil {
		return "", err
	}
	buildCmd := fmt.Sprintf(
		`. /etc/opencode/env.sh 2>/dev/null || true; unset OPENCODE_API_KEY; export OPENCODE_MODEL=${OPENCODE_MODEL:-aseman/default}; aseman-appui build --dir %s --brief-file %s --apps-file %s --title %s --port %d --mode %s --ui %s`,
		shellQuote(dir), shellQuote(briefPath), shellQuote(appsPath), shellQuote(title), port, mode, ui,
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
		var failed appuiReady
		_ = json.Unmarshal([]byte(strings.TrimSpace(readyRaw)), &failed)
		msg := failed.Error
		if msg == "" {
			msg = "OpenCode did not produce a tested READY.json"
		}
		return "", errs.Conflict("appui not ready: " + msg + "\n" + clipTrace(out, 2000))
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
	// The server starts with its app API settings (URL and key).
	start = appServerEnvPrefix(dir) + start

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
	// An Elpian app opens as itself: the client runs its program natively.
	elpianEntry := ""
	if ui == appuiElpian {
		elpianEntry = strings.TrimPrefix(strings.TrimSpace(ready.Elpian), "./")
		if elpianEntry == "" {
			elpianEntry = "elpian/app.js"
		}
		if err := checkElpianEntry(elpianEntry); err != nil {
			return "", err
		}
		proxyArgs["elpian"] = elpianEntry
	} else if w := strings.TrimPrefix(strings.TrimSpace(ready.Widget), "./"); w != "" {
		if err := checkElpianEntry(w); err != nil {
			return "", err
		}
		proxyArgs["widget"] = w
	}
	rawArgs, _ := json.Marshal(proxyArgs)
	proxyOut, err := s.proxyCreateTool(opCtx, spaceID, agentName, string(rawArgs))
	if err != nil {
		return "", err
	}
	// The key works while the app's preview exists.
	if m := proxyPathID.FindStringSubmatch(proxyOut); hasKey && m != nil {
		if pid, perr := identity.Parse(m[1]); perr == nil {
			if err := s.BindAppKey(opCtx, spaceID, dir, pid); err != nil {
				return "", err
			}
		}
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
		"mode":    mode,
		"ui":      ui,
		"next":    "To change this app later, call appui_create again with the same dir and a brief of the change.",
		"proxy":   proxyOut,
		"server_api": map[string]any{
			"url":        sandboxAppAPIURL(),
			"background": hasKey,
			"billing":    "Calls with a request's X-Aseman-User-Token are billed to the person using the app; background calls with ASEMAN_APP_KEY to the person who asked for it.",
		},
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
		Description: "Built-in OpenCode coding agent in the space sandbox. Uses the same metered Aseman LLM gateway as agents (usage billed on the turn). Distribute programming tasks with opencode_run; build interactive fullstack App UIs with appui_create (a native Elpian frontend in Material 3 Expressive by default, @material/web M3E when web is asked for; Aseman light/dark+accent theming; mix OpenUI agent islands with programmed UI via _aseman/kit/openui and _aseman/api/ask); check progress with opencode_status; list models with opencode_models. Generated apps call space apps via _aseman/api/call and open as DeskWeb card windows.",
		Commands: []vmm.ToolCommand{
			{Name: "run", Description: "Send a coding task to OpenCode (platform: opencode_run).", Schema: obj(map[string]any{"message": str("Task"), "dir": str("Optional /workspace/… dir"), "model": str("Optional model; default aseman/default")}, "message")},
			{Name: "status", Description: "Status of an OpenCode / App UI job (platform: opencode_status).", Schema: obj(map[string]any{"dir": str("Project dir under /workspace")})},
			{Name: "models", Description: "Show Aseman LLM backbone / model (platform: opencode_models).", Schema: obj(map[string]any{})},
			{Name: "build", Description: "Build a tested fullstack App UI from a brief (platform: appui_create; M3 Expressive UI by default).", Schema: obj(map[string]any{"brief": str("What to build; omit UI framework to get Material 3 Expressive"), "title": str("Window title"), "apps": map[string]any{"type": "array", "items": map[string]any{"type": "string"}}, "tool": str("Optional dock tool bot id"), "port": map[string]any{"type": "integer"}}, "brief")},
		},
	}
}

// proxyPathID finds a preview's id in proxy_create's output.
var proxyPathID = regexp.MustCompile(`/v1/proxy/([0-9a-f]{32})/`)

// appOwner is the person an app is built for: the person whose request the
// building turn serves (never an agent).
func appOwner(ctx context.Context) identity.ID {
	if actor := vmm.ExecutionFrom(ctx).ActorID; actor != "" {
		if id, err := identity.Parse(actor); err == nil {
			return id
		}
	}
	return helper.Actor(ctx)
}

// appServerEnvFile holds an app server's settings for the app API.
func appServerEnvFile(dir string) string { return dir + "/.aseman/server.env" }

// writeAppServerEnv gives the app its server API settings: the URL, and the
// app's key when it has one. The file is the app's alone (mode 600).
func (s *Service) writeAppServerEnv(ctx context.Context, spaceID identity.ID, dir, key string) error {
	lines := []string{
		"# Written by Aseman for this app's server (see ASEMAN_API.md). Do not commit.",
		"ASEMAN_API_URL=" + sandboxAppAPIURL(),
	}
	if key != "" {
		lines = append(lines, "ASEMAN_APP_KEY="+key)
	}
	path := appServerEnvFile(dir)
	if err := s.sandboxWriteBytes(ctx, spaceID, path, []byte(strings.Join(lines, "\n")+"\n")); err != nil {
		return err
	}
	_, err := s.SandboxExec(ctx, spaceID, "chmod 600 "+shellQuote(path)+"; printf '*\\n' > "+shellQuote(dir+"/.aseman/.gitignore"))
	return err
}

// appServerEnvPrefix loads the app API settings into a start command.
func appServerEnvPrefix(dir string) string {
	f := shellQuote(appServerEnvFile(dir))
	return "set -a; [ -f " + f + " ] && . " + f + "; set +a; "
}
