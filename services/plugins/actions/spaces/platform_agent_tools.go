package spaces

// The tools a person's agents use to give them a product on Aseman:
//
//	platform_setup        an organization and one of its platforms (made or reused)
//	app_developer_access  a developer API key of that organization, written
//	                      into one app's server settings (never the page)
//	platform_publish      a verified app as the platform's frontend (and,
//	                      for an Elpian one, starts its Android app's build)
//	platform_client_build the platform's own Android app: the lightweight
//	                      Elpian client built for its frontend
//	platform_client_status how that build stands, and its download address
//
// Each acts as the person whose request the agent's turn serves (appOwner),
// never as the agent, through the developer namespace's own checks; the
// developer namespace itself stays closed to agents (pkg/agentpolicy). The
// governance gate decides and records each like any other tool.

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Server settings lines a rebuild keeps (app_developer_access writes them).
var keptServerEnv = []string{"ASEMAN_DEVELOPER_API_URL=", "ASEMAN_DEVELOPER_KEY=", "ASEMAN_PLATFORM="}

// sandboxDeveloperAPIURL is where app servers in a sandbox reach the node's
// developer API (models, chat, the platform collection): /dev/v1.
func sandboxDeveloperAPIURL() string {
	return strings.TrimSuffix(sandboxAppAPIURL(), "/appapi/v1") + "/dev/v1"
}

// developerFile records the developer key an app was given, so a later call
// replaces it instead of piling keys up.
func developerFile(dir string) string { return dir + "/.aseman/developer.json" }

func (s *Service) toolPerson(ctx context.Context) (identity.ID, error) {
	person := appOwner(ctx)
	if person.IsZero() || s.isBotAccount(ctx, person) {
		return identity.ID{}, errs.Permission("this acts for the person you are working for, and there is none in this turn")
	}
	return person, nil
}

// platformSetupTool implements platform_setup.
func (s *Service) platformSetupTool(ctx context.Context, argsJSON string) (string, error) {
	var in struct {
		Org     string `json:"org"`
		OrgName string `json:"org_name"`
		Name    string `json:"name"`
		Slug    string `json:"slug"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument(`platform_setup takes {"name", "slug", "org_name"?, "org"?}`)
	}
	person, err := s.toolPerson(ctx)
	if err != nil {
		return "", err
	}
	var out map[string]any
	if err := bridge.Invoke(ctx, s.K, "developer", "SetupPlatform",
		[]any{ctx, person, in.Org, in.OrgName, in.Name, in.Slug}, &out); err != nil {
		return "", err
	}
	out["next"] = "Build the platform's frontend: appui_create with audience \"platform\" (kind app), wired to the space's agents and apps it needs. " +
		"If its server should use the developer API (models, or the platform's own accounts and spaces through the platform collection), call app_developer_access with the app's dir and this platform's slug. " +
		"Build, test, appui_publish, then platform_publish with the dir and this platform's slug (the person may have several platforms)."
	b, _ := json.Marshal(out)
	return string(b), nil
}

// appDeveloperAccessTool implements app_developer_access.
func (s *Service) appDeveloperAccessTool(ctx context.Context, spaceID identity.ID, argsJSON string) (string, error) {
	var in struct {
		Dir         string `json:"dir"`
		Org         string `json:"org"`
		Platform    string `json:"platform"`
		PlatformAPI *bool  `json:"platform_api"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument(`app_developer_access takes {"dir", "platform"?, "org"?, "platform_api"?}`)
	}
	dir := strings.TrimRight(strings.TrimSpace(in.Dir), "/")
	if !strings.HasPrefix(dir, "/workspace/") || strings.Contains(dir, "..") {
		return "", errs.InvalidArgument("dir is the app's project directory under /workspace/ (from appui_create)")
	}
	person, err := s.toolPerson(ctx)
	if err != nil {
		return "", err
	}
	if _, err := s.sandboxReadText(ctx, spaceID, dir+"/JOB.json"); err != nil {
		return "", errs.NotFound("no app project at " + dir + ": start it with appui_create first")
	}
	title := ""
	if raw, err := s.sandboxReadText(ctx, spaceID, dir+"/JOB.json"); err == nil {
		var j struct {
			Title string `json:"title"`
		}
		_ = json.Unmarshal([]byte(raw), &j)
		title = j.Title
	}
	var prev struct {
		KeyID string `json:"key_id"`
	}
	if raw, err := s.sandboxReadText(ctx, spaceID, developerFile(dir)); err == nil {
		_ = json.Unmarshal([]byte(raw), &prev)
	}
	platformAPI := in.PlatformAPI == nil || *in.PlatformAPI
	var access models.AppAccess
	if err := bridge.Invoke(ctx, s.K, "developer", "AppDeveloperKey",
		[]any{ctx, person, in.Org, in.Platform, title, platformAPI, prev.KeyID}, &access); err != nil {
		return "", err
	}
	if access.Secret == "" {
		return "", errs.New(errs.CodeUnavailable, "the developer key was not made")
	}
	settings := map[string]string{
		"ASEMAN_DEVELOPER_API_URL": sandboxDeveloperAPIURL(),
		"ASEMAN_DEVELOPER_KEY":     access.Secret,
	}
	if access.Platform != "" {
		settings["ASEMAN_PLATFORM"] = access.Platform
	}
	if err := s.setAppServerEnv(ctx, spaceID, dir, settings); err != nil {
		return "", err
	}
	record, _ := json.Marshal(map[string]any{"key_id": access.KeyID, "org": access.Org, "platform": access.Platform})
	if err := s.sandboxWriteBytes(ctx, spaceID, developerFile(dir), record); err != nil {
		return "", err
	}
	_, _ = s.SandboxExec(ctx, spaceID, "R=${ASEMAN_APPUI_ROOT:-/opt/aseman-appui}; [ -f \"$R/DEVELOPER.md\" ] && cp -f \"$R/DEVELOPER.md\" "+shellQuote(dir+"/DEVELOPER.md")+"; true")
	scopes := []string{"models", "chat"}
	if platformAPI {
		scopes = append(scopes, "platform collection")
	}
	b, _ := json.Marshal(map[string]any{
		"dir":      dir,
		"org":      access.Org,
		"platform": access.Platform,
		"key":      "written to " + appServerEnvFile(dir) + " as ASEMAN_DEVELOPER_KEY (with ASEMAN_DEVELOPER_API_URL" + map[bool]string{true: ", ASEMAN_PLATFORM", false: ""}[access.Platform != ""] + "); it acts as the person and spends from the organization",
		"scopes":   scopes,
		"next":     "Use it from the app's server only, with the server SDK's Aseman.developer() (DEVELOPER.md): never send the key to the page, log it or commit it.",
	})
	return string(b), nil
}

// setAppServerEnv sets lines of an app's server settings, keeping the rest.
func (s *Service) setAppServerEnv(ctx context.Context, spaceID identity.ID, dir string, values map[string]string) error {
	path := appServerEnvFile(dir)
	current, _ := s.sandboxReadText(ctx, spaceID, path)
	lines := []string{}
	for _, line := range strings.Split(strings.TrimRight(current, "\n"), "\n") {
		key, _, _ := strings.Cut(line, "=")
		if _, replaced := values[strings.TrimSpace(key)]; replaced || line == "" {
			continue
		}
		lines = append(lines, line)
	}
	for _, k := range []string{"ASEMAN_DEVELOPER_API_URL", "ASEMAN_DEVELOPER_KEY", "ASEMAN_PLATFORM"} {
		if v, ok := values[k]; ok {
			lines = append(lines, k+"="+v)
		}
	}
	if err := s.sandboxWriteBytes(ctx, spaceID, path, []byte(strings.Join(lines, "\n")+"\n")); err != nil {
		return err
	}
	_, err := s.SandboxExec(ctx, spaceID, "chmod 600 "+shellQuote(path))
	return err
}

// platformPublishTool implements platform_publish.
func (s *Service) platformPublishTool(ctx context.Context, spaceID, roomID identity.ID, agentName, argsJSON string) (string, error) {
	var in struct {
		Dir      string `json:"dir"`
		Proxy    string `json:"proxy"`
		Org      string `json:"org"`
		Platform string `json:"platform"`
		// Android is false to publish without building the platform's app.
		Android *bool `json:"android"`
		// Godot turns the embedded Godot engine (3D) on in that app.
		Godot *bool `json:"godot"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument(`platform_publish takes {"dir", "platform"?, "org"?}`)
	}
	person, err := s.toolPerson(ctx)
	if err != nil {
		return "", err
	}
	proxyID := strings.TrimSpace(in.Proxy)
	if dir := strings.TrimRight(strings.TrimSpace(in.Dir), "/"); dir != "" {
		var keys []AppKey
		if err := s.R.List(ctx, "app_keys", database.Filter{Equal: map[string]any{"app_id": dir, "space_id": spaceID.String()}, Limit: 1}, &keys); err != nil {
			return "", err
		}
		if len(keys) == 0 || keys[0].ProxyID == "" {
			return "", errs.InvalidArgument("the app at " + dir + " is not published yet: build it and call appui_publish with its dir first")
		}
		proxyID = keys[0].ProxyID
	}
	if proxyID == "" {
		return "", errs.InvalidArgument("name the app by its dir (from appui_create)")
	}
	var view map[string]any
	if err := bridge.Invoke(ctx, s.K, "developer", "PublishFrontendAs", []any{ctx, person, in.Org, in.Platform, proxyID}, &view); err != nil {
		return "", err
	}
	frontend, _ := view["frontend"].(map[string]any)
	url, _ := frontend["url"].(string)
	slug, _ := view["slug"].(string)
	out := map[string]any{
		"platform": view,
		"url":      url,
		"next": "Tell the person their platform is live: its people open " + url + " on this node (or the platform's own Aseman client, built with ASEMAN_PLATFORM=" +
			strings.TrimSuffix(strings.TrimPrefix(url, "/v1/platforms/"), "/app/") + "). Its use of this space's agents and apps runs as the person and is billed to them; it reaches only what the app is wired to. " +
			"Whoever opens it, from anywhere, wakes this space's computer when it is asleep.",
	}
	// An Elpian frontend gets the platform's own Android app.
	if ui, _ := frontend["ui"].(string); ui != appuiWeb && (in.Android == nil || *in.Android) && slug != "" {
		build, err := s.startClientBuildFor(ctx, person, in.Org, slug, models.PlatformClientOptions{Room: roomID.String(), Agent: agentName, Godot: in.Godot})
		switch {
		case err != nil:
			out["android"] = map[string]any{"state": "not started", "error": err.Error()}
		default:
			out["android"] = build
			out["next"] = out["next"].(string) + " Its Android app is building on this computer (" + build.State + "): when it is done it is posted in this room with its download address; " +
				"platform_client_status tells how it stands. Tell the person it is on its way."
		}
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}

// startClientBuildFor starts building the Android app of [person]'s
// platform [platformRef] (or the only one in [orgRef]).
func (s *Service) startClientBuildFor(ctx context.Context, person identity.ID, orgRef, platformRef string, opts models.PlatformClientOptions) (models.PlatformClientBuild, error) {
	var target models.PlatformClientTarget
	if err := bridge.Invoke(ctx, s.K, "developer", "PlatformClientTarget", []any{ctx, person, orgRef, platformRef}, &target); err != nil {
		return models.PlatformClientBuild{}, err
	}
	return s.StartPlatformClientBuild(ctx, person, target, opts)
}

// platformClientBuildTool implements platform_client_build.
func (s *Service) platformClientBuildTool(ctx context.Context, roomID identity.ID, agentName, argsJSON string) (string, error) {
	var in struct {
		Org      string `json:"org"`
		Platform string `json:"platform"`
		Name     string `json:"name"`
		AppID    string `json:"app_id"`
		Version  string `json:"version"`
		Accent   string `json:"accent"`
		NodeURL  string `json:"node_url"`
		Godot    *bool  `json:"godot"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument(`platform_client_build takes {"platform"?, "org"?, "name"?, "app_id"?, "version"?, "accent"?, "node_url"?, "godot"?}`)
	}
	person, err := s.toolPerson(ctx)
	if err != nil {
		return "", err
	}
	build, err := s.startClientBuildFor(ctx, person, in.Org, in.Platform, models.PlatformClientOptions{
		Name: in.Name, AppID: in.AppID, Version: in.Version, Accent: in.Accent, NodeURL: in.NodeURL, Godot: in.Godot, Room: roomID.String(), Agent: agentName,
	})
	if err != nil {
		return "", err
	}
	out := map[string]any{"build": build}
	switch build.State {
	case "building":
		out["next"] = "The app is being made on the frontend space's computer: usually under a minute (the computer carries the app prebuilt and writes this platform into it); " +
			"with Godot, or on a computer without the prebuilt app, it builds with Flutter and takes minutes. " +
			"When it is done it is posted in this room with its download address; platform_client_status tells how it stands meanwhile. Tell the person it is on its way."
	case "failed":
		out["next"] = "The build did not start or failed: tell the person why (build.error)."
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}

// platformClientStatusTool implements platform_client_status.
func (s *Service) platformClientStatusTool(ctx context.Context, argsJSON string) (string, error) {
	var in struct {
		Org      string `json:"org"`
		Platform string `json:"platform"`
	}
	if err := json.Unmarshal([]byte(argsJSON), &in); err != nil {
		return "", errs.InvalidArgument(`platform_client_status takes {"platform"?, "org"?}`)
	}
	person, err := s.toolPerson(ctx)
	if err != nil {
		return "", err
	}
	var target models.PlatformClientTarget
	if err := bridge.Invoke(ctx, s.K, "developer", "PlatformClientTarget", []any{ctx, person, in.Org, in.Platform}, &target); err != nil {
		return "", err
	}
	build, err := s.PlatformClientBuildStatus(ctx, person, target)
	if err != nil {
		return "", err
	}
	b, _ := json.Marshal(map[string]any{"build": build})
	return string(b), nil
}
