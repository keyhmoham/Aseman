package spaces

// App UI generation: on-demand fullstack apps built in the space sandbox,
// calling space apps and agents via the preview `_aseman/api/*` API.
// kind=app (default) opens as a framed desk card window; kind=gadget registers
// the same verified app as a compact frameless free-position gadget (chat / rail /
// desk / page, or account-wide when built in the person's home Aseman).
// The space's agents build them. Both share the project layout, guides and
// toolchain (aseman-appui), and the platform verifies every app the same way.

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"path"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
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
	// Fullstack builds can take several minutes, and a build that
	// fails its checks gets repair rounds (aseman-appui build); verifying an
	// app (aseman-appui verify) replays its end-to-end scenarios.
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

	// Hosting: a framed desk window, or a compact frameless free-position gadget.
	appuiKindApp    = "app"
	appuiKindGadget = "gadget"
)

// appuiKind picks how a verified App UI is hosted.
func appuiKind(asked string) (string, error) {
	switch k := strings.ToLower(strings.TrimSpace(asked)); k {
	case "", appuiKindApp:
		return appuiKindApp, nil
	case appuiKindGadget:
		return appuiKindGadget, nil
	default:
		return "", errs.InvalidArgument(`kind is "app" (framed desk window, the default) or "gadget" (compact frameless free-position widget)`)
	}
}

// appuiGadgetPlacement normalises a gadget's size / surface hint.
func appuiGadgetPlacement(asked string) (string, error) {
	switch p := strings.ToLower(strings.TrimSpace(asked)); p {
	case "", "chat", "panel":
		return "chat", nil
	case "rail", "page", "desk":
		return p, nil
	default:
		return "", errs.InvalidArgument(`placement for a gadget is "chat", "rail", "desk" or "page"`)
	}
}

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

// sandboxReadText reads a file of an app project on the computer itself: the
// app tools have just run there, and what they wrote may not be in the
// stored files yet.
func (s *Service) sandboxReadText(ctx context.Context, spaceID identity.ID, p string) (string, error) {
	data, err := s.sandboxReadLive(ctx, spaceID, p)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// appuiCatalog is what the builder is told about the space it builds for
// (APPS.json): the apps whose microtools the software may call, with their
// argument schemas, and the agents it may ask, so it wires real names and
// real argument shapes instead of guessing. [apps] / [agents] narrow the
// lists to what the brief names (names or bot ids); empty keeps them all.
func (s *Service) appuiCatalog(ctx context.Context, spaceID, roomID identity.ID, apps, agents []string, audience string) ([]byte, error) {
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
	doc := map[string]any{
		"space":  sp,
		"apps":   appList,
		"agents": agentList,
		"api":    "See ASEMAN_API.md: apps via POST _aseman/api/call {tool, microtool, args}; agents via POST _aseman/api/ask {agent, prompt}. vendor/aseman-sdk/aseman.js wraps both.",
		// These are the only agents and apps the software may use, by these
		// names: the platform checks the code against this list before the
		// app is ready (aseman-appui verify), and a platform frontend reaches
		// nothing else of the space.
		"rule": "Wire only these apps (and their microtools) and agents, by exactly these names and ids. Never invent an agent or app, and never stand in for one (a hard-coded reply, a direct model call, a fake endpoint): every agent or app the software uses is called through the Aseman API, from the page or from the server.",
	}
	// The brief named what to wire: each of these is expected to be used.
	if len(apps) > 0 || len(agents) > 0 {
		doc["narrowed"] = true
	}
	if audience == appuiAudiencePlatform {
		doc["audience"] = map[string]any{
			"kind":   appuiAudiencePlatform,
			"people": "the people of a sub-platform the person runs, not members of this space; some arrive signed out",
			"guide":  "PLATFORM.md",
		}
	}
	return json.MarshalIndent(doc, "", "  ")
}

// appuiPlace is where and how a built app opens: on whose desk, its dock
// tool, and its window.
type appuiPlace struct {
	Tool string `json:"tool,omitempty"`
	// Room is the desk the app opens on ("home" for the hall) and
	// ArrangeRoom the room whose desk windows are arranged.
	Room        string   `json:"room"`
	ArrangeRoom string   `json:"arrange_room,omitempty"`
	Show        *bool    `json:"show,omitempty"`
	X           *float64 `json:"x,omitempty"`
	Y           *float64 `json:"y,omitempty"`
	W           *float64 `json:"w,omitempty"`
	H           *float64 `json:"h,omitempty"`
	Compact     bool     `json:"compact,omitempty"`
}

// appuiJob is an app being built: what appui_create prepared, and what
// appui_publish needs to open it (kept in .aseman/publish.json when the
// space's agents build it).
type appuiJob struct {
	ID     string     `json:"id"`
	Dir    string     `json:"dir"`
	Title  string     `json:"title"`
	Port   int        `json:"port"`
	Mode   string     `json:"mode"`
	UI     string     `json:"ui"`
	Kind   string     `json:"kind,omitempty"` // app (default) | gadget
	// Placement is only for kind=gadget: chat | rail | desk | page.
	Placement string `json:"placement,omitempty"`
	// Audience is who the app is for: "space" (its people, the default) or
	// "platform" (a sub-platform's people, as that platform's frontend).
	Audience  string     `json:"audience,omitempty"`
	HasKey    bool       `json:"has_key"`
	Place     appuiPlace `json:"place"`
}

func appuiPublishFile(dir string) string { return dir + "/.aseman/publish.json" }

// appuiDeskPlace resolves where an app opens: on the desk of the room where
// the person asked; room=home targets the hall ("My desk"); an
// explicit room id uses that room.
func appuiDeskPlace(roomID, target identity.ID, room string) (desk string, arrange identity.ID) {
	switch r := strings.TrimSpace(room); {
	case r == "home":
		return "home", identity.ID{}
	case !target.IsZero():
		return target.String(), target
	case !roomID.IsZero():
		return roomID.String(), roomID
	default:
		return "home", identity.ID{}
	}
}

// appuiCreateTool implements appui_create. It prepares the project (brief,
// the space's apps and agents, the app's server API settings), then the
// space's agents build it: the calling agent gets the build task back and
// finishes with appui_publish, which verifies and opens the app.
func (s *Service) appuiCreateTool(ctx context.Context, spaceID, roomID identity.ID, agentName, argsJSON string) (string, error) {
	var in struct {
		Brief     string       `json:"brief"`
		Title     string       `json:"title"`
		Apps      []string     `json:"apps"`
		Agents    []string     `json:"agents"`
		UI        string       `json:"ui"`
		Kind      string       `json:"kind"`
		Placement string       `json:"placement"`
		Audience  string       `json:"audience"`
		Tool      string       `json:"tool"`
		Dir       string       `json:"dir"`
		Port      int          `json:"port"`
		ID        string       `json:"id"`
		X         *float64     `json:"x"`
		Y         *float64     `json:"y"`
		W         *float64     `json:"w"`
		H         *float64     `json:"h"`
		Compact   *DeskCompact `json:"compact"`
		Room      string       `json:"room"`
		Show      *bool        `json:"show"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument("appui_create arguments must be a JSON object")
	}
	brief := strings.TrimSpace(in.Brief)
	if brief == "" {
		return "", errs.InvalidArgument("appui_create needs brief (what to build)")
	}
	kind, err := appuiKind(in.Kind)
	if err != nil {
		return "", err
	}
	placement := ""
	if kind == appuiKindGadget {
		if placement, err = appuiGadgetPlacement(in.Placement); err != nil {
			return "", err
		}
	}
	target, err := deskRoom(roomID, in.Room)
	if err != nil {
		return "", err
	}
	job := appuiJob{ID: strings.TrimSpace(in.ID), Dir: strings.TrimSpace(in.Dir), Port: in.Port, Title: strings.TrimSpace(in.Title), Kind: kind, Placement: placement}
	if job.ID == "" {
		job.ID = newAppUIID()
	}
	if job.Dir == "" {
		// Direct chats share the caller's personal sandbox; hosted apps for
		// that DM are scoped under /workspace/dms/<directSpace>/appui.
		root := appuiRoot
		if sp, err := s.GetSpace(ctx, spaceID); err == nil && sp != nil && sp.Direct {
			root = "/workspace/dms/" + spaceID.EntityString() + "/appui"
		}
		job.Dir = root + "/" + job.ID
	}
	if !strings.HasPrefix(job.Dir, "/workspace/") {
		return "", errs.InvalidArgument("dir must be under /workspace/")
	}
	if job.Port == 0 {
		job.Port = appuiPortFor(job.ID)
	}
	if job.Port < 1 || job.Port > 65535 {
		return "", errs.InvalidArgument("port must be in 1..65535")
	}
	if job.Title == "" {
		job.Title = "App"
	}
	desk, arrange := appuiDeskPlace(roomID, target, in.Room)
	job.Place = appuiPlace{Tool: strings.TrimSpace(in.Tool), Room: desk, Show: in.Show,
		X: in.X, Y: in.Y, W: in.W, H: in.H, Compact: in.Compact != nil}
	if !arrange.IsZero() {
		job.Place.ArrangeRoom = arrange.String()
	}

	// App UI builds routinely exceed the short deadlines that wrap agent / Code
	// Mode tool calls. Keep values (actor, run id, TurnLLM, stop) but detach
	// the clock so READY.json can still be read after a long build.
	opCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), appuiBuildWait)
	defer cancel()

	wantApps := in.Apps
	if t := strings.TrimSpace(in.Tool); t != "" && len(wantApps) > 0 {
		wantApps = append(wantApps, t)
	}
	// A project built before keeps who it was built for unless asked again.
	existingAudience := ""
	if raw, jerr := s.sandboxReadText(opCtx, spaceID, appuiPublishFile(job.Dir)); jerr == nil {
		var prev appuiJob
		if json.Unmarshal([]byte(raw), &prev) == nil {
			existingAudience = prev.Audience
		}
	}
	if job.Audience, err = appuiAudience(in.Audience, existingAudience); err != nil {
		return "", err
	}
	if job.Audience == appuiAudiencePlatform && kind == appuiKindGadget {
		return "", errs.InvalidArgument("a platform's frontend is a framed app (kind app), not a gadget")
	}
	catalog, err := s.appuiCatalog(opCtx, spaceID, target, wantApps, in.Agents, job.Audience)
	if err != nil {
		return "", err
	}

	dir := job.Dir
	briefPath := dir + "/.aseman-brief.md"
	appsPath := dir + "/.aseman-apps.json"
	if err := s.sandboxWriteBytes(opCtx, spaceID, briefPath, []byte(brief+"\n")); err != nil {
		return "", err
	}
	if err := s.sandboxWriteBytes(opCtx, spaceID, appsPath, catalog); err != nil {
		return "", err
	}
	// The app's server uses the space's agents and apps too: with the token
	// of the person using it (sent with each request), or, for work nobody
	// is in front of, with the app's key, which acts for and bills the person
	// who asked for the app.
	if owner := appOwner(ctx); !owner.IsZero() {
		key, kerr := s.IssueAppKey(opCtx, spaceID, target, owner, dir, job.Title)
		if kerr != nil {
			return "", kerr
		}
		if err := s.writeAppServerEnv(opCtx, spaceID, dir, key); err != nil {
			return "", err
		}
		job.HasKey = true
	} else if err := s.writeAppServerEnv(opCtx, spaceID, dir, ""); err != nil {
		return "", err
	}

	// A project that was built before is changed in place (a follow-up:
	// "add a filter", "fix the chart"), not rebuilt from nothing.
	job.Mode = "new"
	existingUI := ""
	if raw, jerr := s.sandboxReadText(opCtx, spaceID, dir+"/JOB.json"); jerr == nil && strings.TrimSpace(raw) != "" {
		job.Mode = "update"
		var j struct {
			UI string `json:"ui"`
		}
		if json.Unmarshal([]byte(raw), &j) == nil {
			existingUI = j.UI
		}
		if existingUI == "" {
			existingUI = appuiWeb // built before Elpian became the default
		}
	}
	if job.UI, err = appuiFrontend(in.UI, existingUI); err != nil {
		return "", err
	}
	flags := fmt.Sprintf(`--dir %s --brief-file %s --apps-file %s --title %s --port %d --mode %s --ui %s --kind %s --audience %s`,
		shellQuote(dir), shellQuote(briefPath), shellQuote(appsPath), shellQuote(job.Title), job.Port, job.Mode, job.UI, job.Kind, job.Audience)
	return s.appuiAgentsBuild(opCtx, spaceID, job, flags)
}

// appuiAgentsBuild hands an app to the space's agents: the sandbox lays the
// project out, and the calling agent gets the build task (TASK.md) to do
// with its own tools. It builds,
// tests and drives the app, then calls appui_publish.
func (s *Service) appuiAgentsBuild(ctx context.Context, spaceID identity.ID, job appuiJob, flags string) (string, error) {
	out, err := s.appuiExec(ctx, spaceID, "aseman-appui prepare "+flags)
	if err != nil {
		return "", err
	}
	if !strings.HasPrefix(out, "exit=0\n") {
		return "", errs.New(errs.CodeUnavailable, "appui prepare failed (is the sandbox image current?): "+clipTrace(out, 2000))
	}
	raw, _ := json.Marshal(job)
	if err := s.sandboxWriteBytes(ctx, spaceID, appuiPublishFile(job.Dir), raw); err != nil {
		return "", err
	}
	task, terr := s.sandboxReadText(ctx, spaceID, job.Dir+"/TASK.md")
	if terr != nil || strings.TrimSpace(task) == "" {
		task = strings.TrimPrefix(out, "exit=0\n")
	}
	hostHint := "opens it on the desk"
	if job.Kind == appuiKindGadget {
		hostHint = "registers it as a compact frameless gadget (" + job.Placement + ")"
	}
	if job.Audience == appuiAudiencePlatform {
		hostHint += "; the person then publishes it as their platform's frontend (Developer API → Platform → Frontend)"
	}
	next := "Build the app now, exactly as the task says (or hand the whole task to a developer agent of the space with this dir and TASK.md): plan, build, test, drive it end to end with aseman-elpian, write READY.json. Then call appui_publish {\"dir\": \"" + job.Dir + "\"}: the platform verifies it and " + hostHint + ", or answers with what to fix."
	b, _ := json.Marshal(map[string]any{
		"state":     "building",
		"builder":   "agents",
		"id":        job.ID,
		"dir":       job.Dir,
		"title":     job.Title,
		"port":      job.Port,
		"mode":      job.Mode,
		"ui":        job.UI,
		"kind":      job.Kind,
		"placement": job.Placement,
		"audience":  job.Audience,
		"task":      clipTrace(task, 12000),
		"next":      next,
		"server_api": map[string]any{
			"url":        sandboxAppAPIURL(),
			"background": job.HasKey,
			"billing":    "Calls with a request's X-Aseman-User-Token are billed to the person using the app; background calls with ASEMAN_APP_KEY to the person who asked for it.",
		},
	})
	return string(b), nil
}

// appuiExec runs an aseman-appui command for the agents' builds. A machine
// still awake on an image older than those commands (the node was upgraded
// while it ran) is restarted once, which brings it onto the current image
// (its /workspace stays), and the command runs again.
func (s *Service) appuiExec(ctx context.Context, spaceID identity.ID, cmd string) (string, error) {
	out, err := s.SandboxExec(ctx, spaceID, cmd)
	if err != nil || !strings.Contains(out, "aseman-appui: unknown command") {
		return out, err
	}
	s.L.Info("sandbox tools are older than the node: restarting the machine on the current image", "space", spaceID.String())
	// Other agents' commands may be running on it: wait for a gap.
	for try := 0; try < 12; try++ {
		if _, err = s.SandboxStop(ctx, spaceID); errs.CodeOf(err) != errs.CodeConflict {
			break
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(10 * time.Second):
		}
	}
	if err != nil {
		return "", errs.New(errs.CodeUnavailable, "the project's computer runs an older image without the app tools, and it could not be restarted now ("+err.Error()+"); try again in a moment")
	}
	return s.SandboxExec(ctx, spaceID, cmd)
}

// appuiPublishTool implements appui_publish: the platform's checks of an app
// the space's agents built (READY.json, the app starting and answering, an
// Elpian frontend bundled, run on QuickJS against its server and its
// end-to-end scenarios replayed), then the app opens on the desk. A failed
// check answers with the problem and how to repair it; fix and call again.
// It also re-verifies and reopens any app.
func (s *Service) appuiPublishTool(ctx context.Context, spaceID, roomID identity.ID, agentName, argsJSON string) (string, error) {
	var in struct {
		Dir       string   `json:"dir"`
		Title     string   `json:"title"`
		Kind      string   `json:"kind"`
		Placement string   `json:"placement"`
		Tool      string   `json:"tool"`
		Room      string   `json:"room"`
		Show      *bool    `json:"show"`
		X         *float64 `json:"x"`
		Y         *float64 `json:"y"`
		W         *float64 `json:"w"`
		H         *float64 `json:"h"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument("appui_publish arguments must be a JSON object: {\"dir\": \"/workspace/appui/<id>\"}")
	}
	dir := strings.TrimRight(strings.TrimSpace(in.Dir), "/")
	if !strings.HasPrefix(dir, "/workspace/") || strings.Contains(dir, "..") {
		return "", errs.InvalidArgument("appui_publish needs dir: the app's project directory under /workspace/ (from appui_create)")
	}
	opCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), appuiBuildWait)
	defer cancel()

	var job appuiJob
	if raw, err := s.sandboxReadText(opCtx, spaceID, appuiPublishFile(dir)); err == nil {
		_ = json.Unmarshal([]byte(raw), &job)
	}
	if job.Dir == "" {
		// Not prepared by appui_create (an older node, or a build it could
		// not set up): the project says what it is, in JOB.json or, built by
		// hand, in READY.json. The platform's checks decide the rest.
		raw, err := s.sandboxReadText(opCtx, spaceID, dir+"/JOB.json")
		if err != nil {
			raw, err = s.sandboxReadText(opCtx, spaceID, dir+"/READY.json")
		}
		if err != nil {
			return "", errs.NotFound("nothing to publish at " + dir + ": it has no JOB.json or READY.json. Build the app there (start it with appui_create) and write READY.json once its tests pass, then call appui_publish again")
		}
		var j struct {
			Title string `json:"title"`
			Port  int    `json:"port"`
			Mode  string `json:"mode"`
			UI    string `json:"ui"`
		}
		_ = json.Unmarshal([]byte(raw), &j)
		desk, arrange := appuiDeskPlace(roomID, roomID, "")
		job = appuiJob{ID: path.Base(dir), Title: j.Title, Port: j.Port, Mode: j.Mode, UI: j.UI, Place: appuiPlace{Room: desk}}
		if !arrange.IsZero() {
			job.Place.ArrangeRoom = arrange.String()
		}
		if env, err := s.sandboxReadText(opCtx, spaceID, appServerEnvFile(dir)); err == nil {
			job.HasKey = strings.Contains(env, "ASEMAN_APP_KEY=")
		}
	}
	job.Dir = dir
	if t := strings.TrimSpace(in.Title); t != "" {
		job.Title = t
	}
	if k := strings.TrimSpace(in.Kind); k != "" {
		kind, kerr := appuiKind(k)
		if kerr != nil {
			return "", kerr
		}
		job.Kind = kind
	}
	if job.Kind == "" {
		job.Kind = appuiKindApp
	}
	if job.Kind == appuiKindGadget {
		place := in.Placement
		if place == "" {
			place = job.Placement
		}
		p, perr := appuiGadgetPlacement(place)
		if perr != nil {
			return "", perr
		}
		job.Placement = p
	}
	if t := strings.TrimSpace(in.Tool); t != "" {
		job.Place.Tool = t
	}
	if r := strings.TrimSpace(in.Room); r != "" {
		target, err := deskRoom(roomID, r)
		if err != nil {
			return "", err
		}
		desk, arrange := appuiDeskPlace(roomID, target, r)
		job.Place.Room, job.Place.ArrangeRoom = desk, ""
		if !arrange.IsZero() {
			job.Place.ArrangeRoom = arrange.String()
		}
	}
	if in.Show != nil {
		job.Place.Show = in.Show
	}
	for _, v := range []struct {
		to   **float64
		from *float64
	}{{&job.Place.X, in.X}, {&job.Place.Y, in.Y}, {&job.Place.W, in.W}, {&job.Place.H, in.H}} {
		if v.from != nil {
			*v.to = v.from
		}
	}

	out, err := s.appuiExec(opCtx, spaceID, "aseman-appui verify --dir "+shellQuote(dir))
	if err != nil {
		return "", err
	}
	if !strings.HasPrefix(out, "exit=0\n") {
		return "", errs.Conflict("appui not ready: the platform checked the app and it is not ready yet. Fix the root cause, run your tests again, rewrite READY.json and call appui_publish again.\n" + clipTrace(out, 6000))
	}
	readyRaw, _ := s.sandboxReadText(opCtx, spaceID, dir+"/READY.json")
	ready, ok := parseAppuiReadyJSON(readyRaw)
	if !ok {
		return "", errs.Conflict("appui not ready: READY.json needs ok, tested, start and port")
	}
	if job.UI == "" {
		job.UI = ready.UI
	}
	if job.UI != appuiWeb {
		job.UI = appuiElpian
	}
	return s.appuiOpen(opCtx, ctx, spaceID, agentName, job, ready, "agents")
}

// appuiOpen serves a verified app: as a framed desk card (kind=app) or as a
// compact frameless gadget (kind=gadget). The preview gateway runs its
// start command either way; gadgets keep the desk window off (show=false).
func (s *Service) appuiOpen(opCtx, ctx context.Context, spaceID identity.ID, agentName string, job appuiJob, ready appuiReady, builder string) (string, error) {
	dir, port, title := job.Dir, job.Port, job.Title
	if ready.Port > 0 {
		port = ready.Port
	}
	if ready.Title != "" {
		title = ready.Title
	}
	start := appuiStartCommand(dir, port, ready.Start)
	if job.Kind == "" {
		job.Kind = appuiKindApp
	}

	show := true
	if job.Kind == appuiKindGadget {
		show = false
	} else if job.Place.Show != nil {
		show = *job.Place.Show
	}
	proxyArgs := map[string]any{
		"port":  port,
		"title": title,
		"start": start,
		"show":  show,
		"tool":  job.Place.Tool,
		"room":  job.Place.Room,
	}
	elpianEntry := ""
	// An Elpian app opens as itself: the client runs its program natively.
	if job.UI == appuiElpian {
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
	if strings.Contains(proxyOut, "did not answer within") {
		next := "Fix it and call appui_create again with the same dir."
		if builder == "agents" {
			next = "Fix it and call appui_publish again."
		}
		return "", errs.Conflict("the app passed its checks but did not start (its start command, run as the preview runs it, did not answer on port " +
			strconv.Itoa(port) + "). " + next + "\n" + clipTrace(proxyOut, 3000))
	}
	m := proxyPathID.FindStringSubmatch(proxyOut)
	// The key works while the app's preview exists.
	if job.HasKey && m != nil {
		if pid, perr := identity.Parse(m[1]); perr == nil {
			if err := s.BindAppKey(opCtx, spaceID, dir, pid, s.appKeyMetaFor(opCtx, spaceID, job, elpianEntry)); err != nil {
				return "", err
			}
		}
	}

	var gadgetOut any
	if job.Kind == appuiKindGadget {
		if m == nil {
			return "", errs.Conflict("the app started but its preview path was not returned; call appui_publish again")
		}
		preview := "/v1/proxy/" + m[1] + "/"
		gadgetOut, err = s.appuiRegisterGadget(opCtx, spaceID, agentName, job, title, preview, elpianEntry)
		if err != nil {
			return "", err
		}
	} else {
		// Optional desk placement after open.
		p := job.Place
		if p.X != nil || p.Y != nil || p.W != nil || p.H != nil || p.Compact {
			arrangeRoom, _ := identity.Parse(p.ArrangeRoom)
			_ = s.appuiArrangeHint(ctx, spaceID, arrangeRoom, agentName, p.X, p.Y, p.W, p.H)
		}
	}

	next := "To change this app later, call appui_create again with the same dir and a brief of the change."
	if builder == "agents" {
		next += " Build the change as its task says, then call appui_publish with the dir again."
	}
	result := map[string]any{
		"id":        job.ID,
		"dir":       dir,
		"title":     title,
		"port":      port,
		"start":     start,
		"summary":   ready.Summary,
		"tested":    true,
		"mode":      job.Mode,
		"ui":        job.UI,
		"kind":      job.Kind,
		"placement": job.Placement,
		"builder":   builder,
		"next":      next,
		"proxy":     proxyOut,
		"server_api": map[string]any{
			"url":        sandboxAppAPIURL(),
			"background": job.HasKey,
			"billing":    "Calls with a request's X-Aseman-User-Token are billed to the person using the app; background calls with ASEMAN_APP_KEY to the person who asked for it.",
		},
	}
	if gadgetOut != nil {
		result["gadget"] = gadgetOut
	}
	if job.Audience == appuiAudiencePlatform {
		result["audience"] = job.Audience
		result["platform"] = map[string]any{
			"publish": "Tell the person the app is ready to be their platform's frontend: in Developer API → Platform → Frontend they pick \"" + title + "\" and publish it. Its people then open it at /v1/platforms/<slug>/app/ (or in an Aseman client signed in to the platform); its use of this space's agents and apps runs as, and is billed to, the person who publishes it.",
		}
	}
	b, _ := json.Marshal(result)
	return string(b), nil
}

// appuiRegisterGadget registers a verified App UI as a compact frameless gadget.
// Built in the person's home Aseman → account-wide (universal) gadget;
// otherwise a space gadget on the given placement.
func (s *Service) appuiRegisterGadget(ctx context.Context, spaceID identity.ID, agentName string, job appuiJob, title, preview, entry string) (any, error) {
	owner := appOwner(ctx)
	if owner.IsZero() {
		return nil, errs.Permission("no person to create the gadget for")
	}
	gadgetSpace := spaceID.String()
	if sp, err := s.GetSpace(ctx, spaceID); err == nil && sp != nil && sp.Home {
		gadgetSpace = "" // account-wide / platform gadget
	}
	var out any
	err := bridge.Invoke(ctx, s.K, "tools", "RegisterAppGadget", []any{
		ctx, owner.String(), gadgetSpace, title, "", job.Placement, job.UI, preview, entry, job.ID, agentName,
	}, &out)
	if err != nil {
		return nil, err
	}
	return out, nil
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



func mustJSONString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}


// appuiStatusTool reads a project's STATUS.json / READY.json (whoever builds
// it): appui_status.
func (s *Service) appuiStatusTool(ctx context.Context, spaceID identity.ID, argsJSON string) (string, error) {
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
	// A rebuild keeps the developer access app_developer_access gave the app.
	if current, err := s.sandboxReadText(ctx, spaceID, path); err == nil {
		for _, line := range strings.Split(current, "\n") {
			for _, kept := range keptServerEnv {
				if strings.HasPrefix(line, kept) {
					lines = append(lines, line)
				}
			}
		}
	}
	if err := s.sandboxWriteBytes(ctx, spaceID, path, []byte(strings.Join(lines, "\n")+"\n")); err != nil {
		return err
	}
	_, err := s.SandboxExec(ctx, spaceID, "chmod 600 "+shellQuote(path)+"; printf '*\\n' > "+shellQuote(dir+"/.aseman/.gitignore"))
	return err
}

// appuiStartCommand is how the preview starts a verified app: as
// aseman-appui verify ran it (from the project directory, under bash, with
// PORT and HOST), with the app's server API settings loaded. The preview
// itself runs commands with sh from /workspace.
func appuiStartCommand(dir string, port int, start string) string {
	return appServerEnvPrefix(dir) + "cd " + shellQuote(dir) + " && export PORT=" + strconv.Itoa(port) +
		" HOST=0.0.0.0 && exec bash -c " + shellQuote(strings.TrimSpace(start))
}

// appServerEnvPrefix loads the app API settings into a start command.
func appServerEnvPrefix(dir string) string {
	f := shellQuote(appServerEnvFile(dir))
	return "set -a; [ -f " + f + " ] && . " + f + "; set +a; "
}
