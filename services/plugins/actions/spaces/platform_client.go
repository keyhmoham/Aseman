package spaces

// A platform's own Android app.
//
// When an Elpian app is published as a platform's frontend, the platform
// gets an app of its own: the lightweight Elpian client (app/platform_client:
// the Elpian engine and what it needs to reach Aseman, nothing else), built
// with the frontend's address in it — the platform's door to the Elpian
// app's proxy, /v1/platforms/<slug>/app/ on this node's public address.
//
// The build runs on the frontend space's computer (aseman-platform-client,
// deploy/sandbox-computer/platform-client), detached: it takes minutes, and
// the computer runs one command at a time for everyone. The node watches it
// (each look keeps the computer awake for the build), then stores the APK as
// a file of the space, records it on the platform (developer namespace), and
// posts it in the room the build was asked from. Anyone downloads it at
// /v1/platforms/<slug>/client/android.apk.
//
// The app wakes the platform's computer whenever it is opened, on any phone
// anywhere: waking is the node's (_aseman/wake, platform_wake.go), not the
// space's.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

const (
	// clientBuildPoll is how often a build is looked at (and its computer
	// kept awake: well inside the computer's idle window).
	clientBuildPoll = 15 * time.Second
	// clientBuildTimeout bounds a build, the first one on a computer
	// (downloading Flutter and the Android SDK) included.
	clientBuildTimeout = 75 * time.Minute
	// clientBuilder is the build tool on the computer.
	clientBuilder = "aseman-platform-client"
	// apkMime is an APK's media type.
	apkMime = "application/vnd.android.package-archive"
)

// clientReadRetry is how long to wait before reading a just-built app again.
var clientReadRetry = 10 * time.Second

var (
	clientSlugRE    = regexp.MustCompile(`^[a-z][a-z0-9-]{1,47}$`)
	clientAppIDRE   = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$`)
	clientVersionRE = regexp.MustCompile(`^\d{1,4}\.\d{1,4}\.\d{1,6}$`)
	clientAccentRE  = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)
)

// clientBuild is one build of a platform's client, watched by the node.
type clientBuild struct {
	target  models.PlatformClientTarget
	person  identity.ID
	space   identity.ID
	room    identity.ID
	agent   string
	node    string
	version string
	appID   string
	started time.Time

	mu     sync.Mutex
	status models.PlatformClientBuild
	done   chan struct{}
}

func (b *clientBuild) report() models.PlatformClientBuild {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.status
}

func (b *clientBuild) set(fn func(*models.PlatformClientBuild)) {
	b.mu.Lock()
	fn(&b.status)
	b.mu.Unlock()
}

// Where a platform's client lives on the computer: the APK and its signing
// key in the project's files (kept), the build's state and project in /tmp
// (the machine's, gone with it).
func clientDir(slug string) string   { return "/workspace/.aseman/platform-clients/" + slug }
func clientAPK(slug string) string   { return clientDir(slug) + "/" + slug + ".apk" }
func clientState(slug string) string { return "/tmp/aseman-platform-client/" + slug }

// publicNodeURL is the address phones reach this node at.
func publicNodeURL(asked string) (string, error) {
	raw := strings.TrimRight(strings.TrimSpace(asked), "/")
	if raw == "" {
		raw = strings.TrimRight(strings.TrimSpace(os.Getenv("ASEMAN_PUBLIC_URL")), "/")
	}
	if raw == "" {
		return "", errs.New(errs.CodeUnavailable, "this node has no public address (ASEMAN_PUBLIC_URL), so a phone could not reach it: ask the node's admin to set it, or name it with node_url")
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.RawQuery != "" || u.Fragment != "" {
		return "", errs.InvalidArgument("the node's public address must be an http(s) origin, e.g. https://aseman.example")
	}
	return raw, nil
}

// PlatformClientURL is where anyone downloads platform [slug]'s client.
func platformClientURL(node, slug string) string {
	return node + "/v1/platforms/" + slug + "/client/android.apk"
}

// nextClientVersion is one past [last] (x.y.z → x.y.z+1), or 1.0.0.
func nextClientVersion(last string) string {
	parts := strings.Split(last, ".")
	if len(parts) == 3 && clientVersionRE.MatchString(last) {
		n, _ := strconv.Atoi(parts[2])
		return parts[0] + "." + parts[1] + "." + strconv.Itoa(n+1)
	}
	return "1.0.0"
}

func (s *Service) clientExec(ctx context.Context, space identity.ID, command string) (string, error) {
	if s.clientExecFn != nil {
		return s.clientExecFn(ctx, space, command)
	}
	return s.SandboxExec(ctx, space, command)
}

func (s *Service) clientRead(ctx context.Context, space identity.ID, path string) ([]byte, error) {
	if s.clientReadFn != nil {
		return s.clientReadFn(ctx, space, path)
	}
	return s.sandboxReadFile(ctx, space, path)
}

func (s *Service) recordClient(ctx context.Context, platformID string, c models.PlatformClient) error {
	if s.clientRecordFn != nil {
		return s.clientRecordFn(ctx, platformID, c)
	}
	return bridge.Invoke(ctx, s.K, "developer", "RecordPlatformClient", []any{ctx, platformID, c})
}

// StartPlatformClientBuild starts building the Android client of the
// platform [target] describes, for its published Elpian frontend, on the
// frontend space's computer, as [person] (who must be a member of that
// space; the developer namespace checked they manage the platform). A build
// under way is reported, not started again.
func (s *Service) StartPlatformClientBuild(ctx context.Context, person identity.ID, target models.PlatformClientTarget, opts models.PlatformClientOptions) (models.PlatformClientBuild, error) {
	if !clientSlugRE.MatchString(target.Slug) {
		return models.PlatformClientBuild{}, errs.InvalidArgument("platform")
	}
	if target.ProxyID == "" {
		return models.PlatformClientBuild{}, errs.InvalidArgument(target.Name + " has no published frontend yet: publish its Elpian app first (platform_publish)")
	}
	if target.UI == appuiWeb {
		return models.PlatformClientBuild{}, errs.InvalidArgument(target.Name + "'s frontend is a web app: its people open it in any browser at /v1/platforms/" + target.Slug +
			"/app/ (it wakes the platform's computer the same way); the Android app is for an Elpian frontend")
	}
	space, err := identity.Parse(target.SpaceID)
	if err != nil {
		return models.PlatformClientBuild{}, errs.InvalidArgument("the frontend's space")
	}
	if _, err := s.SpaceMembership(ctx, space, person); err != nil {
		return models.PlatformClientBuild{}, errs.Permission("the app is built on the computer of the frontend's space, and you are not a member of it")
	}
	node, err := publicNodeURL(opts.NodeURL)
	if err != nil {
		return models.PlatformClientBuild{}, err
	}
	name := strings.TrimSpace(opts.Name)
	if name == "" {
		name = target.Name
	}
	if len([]rune(name)) > 50 {
		name = string([]rune(name)[:50])
	}
	appID := strings.TrimSpace(opts.AppID)
	if appID == "" && target.Client != nil {
		appID = target.Client.AppID // the same app, updated
	}
	if appID == "" {
		appID = "io.aseman.platform." + strings.ReplaceAll(target.Slug, "-", "_")
	}
	if !clientAppIDRE.MatchString(appID) || len(appID) > 150 {
		return models.PlatformClientBuild{}, errs.InvalidArgument("app_id is an Android application id, e.g. com.example.shop")
	}
	version := strings.TrimSpace(opts.Version)
	if version == "" {
		last := ""
		if target.Client != nil {
			last = target.Client.Version
		}
		version = nextClientVersion(last)
	}
	if !clientVersionRE.MatchString(version) {
		return models.PlatformClientBuild{}, errs.InvalidArgument("version is major.minor.patch, e.g. 1.2.0")
	}
	accent := strings.TrimSpace(opts.Accent)
	if accent != "" && !clientAccentRE.MatchString(accent) {
		return models.PlatformClientBuild{}, errs.InvalidArgument("accent is a color like #4F5BD5")
	}
	room, _ := identity.Parse(strings.TrimSpace(opts.Room))

	s.clientBuildMu.Lock()
	if s.clientBuilds == nil {
		s.clientBuilds = map[string]*clientBuild{}
	}
	if b := s.clientBuilds[target.Slug]; b != nil && b.report().State == "building" {
		s.clientBuildMu.Unlock()
		return b.report(), nil
	}
	b := &clientBuild{
		target: target, person: person, space: space, room: room, agent: strings.TrimSpace(opts.Agent),
		node: node, version: version, appID: appID, started: time.Now(), done: make(chan struct{}),
		status: models.PlatformClientBuild{Platform: target.Slug, State: "building", Step: "starting", Version: version,
			Started: time.Now().UTC().Format(time.RFC3339)},
	}
	s.clientBuilds[target.Slug] = b
	s.clientBuildMu.Unlock()

	frontend := node + "/v1/platforms/" + target.Slug + "/app/"
	state := clientState(target.Slug)
	args := []string{clientBuilder, "build", "--frontend", frontend, "--out", clientAPK(target.Slug), "--state", state,
		"--name", name, "--app-id", appID, "--version", version, "--build-number", strconv.FormatInt(time.Now().Unix()/60, 10)}
	if accent != "" {
		args = append(args, "--accent", accent)
	}
	quoted := make([]string, len(args))
	for i, a := range args {
		quoted[i] = shellQuote(a)
	}
	command := fmt.Sprintf("command -v %s >/dev/null || { echo 'this computer has no %s: its image predates platform clients; rebuild the sandbox image'; exit 3; }; "+
		"mkdir -p %s %s && rm -f %s/status.json && (cd /tmp && nohup %s >%s/run.log 2>&1 </dev/null &) && echo started",
		clientBuilder, clientBuilder, shellQuote(state), shellQuote(clientDir(target.Slug)), shellQuote(state), strings.Join(quoted, " "), shellQuote(state))
	wctx := helper.WithActor(context.WithoutCancel(ctx), person)
	out, err := s.clientExec(wctx, space, command)
	if err != nil || !strings.Contains(out, "started") {
		why := strings.TrimSpace(strings.TrimPrefix(out, "exit=3"))
		if err != nil {
			why = err.Error()
		}
		s.finishClientBuild(b, func(st *models.PlatformClientBuild) {
			st.State, st.Error = "failed", "the build did not start: "+clipText(why, 400)
		})
		return b.report(), nil
	}
	go s.watchClientBuild(b)
	return b.report(), nil
}

// PlatformClientBuildStatus is how the latest build of [target]'s client
// stands: the one this node watches, else what its computer last wrote,
// else the client built before.
func (s *Service) PlatformClientBuildStatus(ctx context.Context, person identity.ID, target models.PlatformClientTarget) (models.PlatformClientBuild, error) {
	s.clientBuildMu.Lock()
	b := s.clientBuilds[target.Slug]
	s.clientBuildMu.Unlock()
	if b != nil {
		return b.report(), nil
	}
	out := models.PlatformClientBuild{Platform: target.Slug, State: "none"}
	if c := target.Client; c != nil {
		out.State, out.Version, out.Size, out.Started = "done", c.Version, c.Size, c.BuiltAt
		if node, err := publicNodeURL(""); err == nil {
			out.URL = platformClientURL(node, target.Slug)
		} else {
			out.URL = "/v1/platforms/" + target.Slug + "/client/android.apk"
		}
	}
	return out, nil
}

// clientLook is what one look at a build on the computer saw.
type clientLook struct {
	running bool
	status  struct {
		State   string `json:"state"`
		Step    string `json:"step"`
		Error   string `json:"error"`
		Log     string `json:"log"`
		APK     string `json:"apk"`
		Size    int64  `json:"size"`
		SHA256  string `json:"sha256"`
		Version string `json:"version"`
	}
}

// lookAtClientBuild reads a build's status on the computer and whether its
// process still runs.
func (s *Service) lookAtClientBuild(ctx context.Context, b *clientBuild) (clientLook, error) {
	state := shellQuote(clientState(b.target.Slug) + "/status.json")
	// [a]… keeps pgrep from finding this very command's shell.
	command := "r=0; pgrep -f '[" + clientBuilder[:1] + "]" + clientBuilder[1:] + " build' >/dev/null && r=1; echo \"running=$r\"; " +
		"if [ -f " + state + " ]; then jq -c . " + state + "; else echo '{\"state\":\"none\"}'; fi"
	var look clientLook
	out, err := s.clientExec(ctx, b.space, command)
	if err != nil {
		return look, err
	}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case line == "running=1":
			look.running = true
		case strings.HasPrefix(line, "{"):
			_ = json.Unmarshal([]byte(line), &look.status)
		}
	}
	return look, nil
}

// watchClientBuild follows a build until it is done (then stores and
// records the APK) or failed.
func (s *Service) watchClientBuild(b *clientBuild) {
	ctx, cancel := context.WithTimeout(helper.WithActor(context.Background(), b.person), clientBuildTimeout)
	defer cancel()
	poll := clientBuildPoll
	if s.clientPollEvery > 0 {
		poll = s.clientPollEvery
	}
	stale := 0
	for {
		select {
		case <-ctx.Done():
			s.finishClientBuild(b, func(st *models.PlatformClientBuild) {
				st.State, st.Error = "failed", "the build took longer than "+clientBuildTimeout.String()
			})
			return
		case <-time.After(poll):
		}
		look, err := s.lookAtClientBuild(ctx, b)
		if err != nil {
			if stale++; stale >= 8 {
				s.finishClientBuild(b, func(st *models.PlatformClientBuild) {
					st.State, st.Error = "failed", "the computer stopped answering: "+err.Error()
				})
				return
			}
			continue
		}
		stale = 0
		switch look.status.State {
		case "done":
			s.collectClient(ctx, b, look)
			return
		case "failed":
			s.finishClientBuild(b, func(st *models.PlatformClientBuild) {
				st.State, st.Step, st.Error, st.Log = "failed", look.status.Step, look.status.Error, clipText(look.status.Log, 3000)
			})
			return
		default:
			if !look.running && time.Since(b.started) > 2*poll {
				s.finishClientBuild(b, func(st *models.PlatformClientBuild) {
					st.State, st.Error = "failed", "the build stopped before it finished (its computer may have restarted); build again"
				})
				return
			}
			b.set(func(st *models.PlatformClientBuild) {
				if look.status.Step != "" {
					st.Step = look.status.Step
				}
			})
		}
	}
}

// collectClient stores a finished build's APK, records it on the platform
// and posts it where it was asked for.
func (s *Service) collectClient(ctx context.Context, b *clientBuild, look clientLook) {
	fail := func(why string) {
		s.finishClientBuild(b, func(st *models.PlatformClientBuild) { st.State, st.Error = "failed", why })
	}
	b.set(func(st *models.PlatformClientBuild) { st.Step = "storing the app" })
	path := look.status.APK
	if path == "" {
		path = clientAPK(b.target.Slug)
	}
	if look.status.Size > maxFileSize {
		fail(fmt.Sprintf("the built app is %.0f MB, more than the %d MB a stored file may be", float64(look.status.Size)/(1<<20), maxFileSize>>20))
		return
	}
	// The project's stored files can lag the computer a moment (a provider's
	// volume syncs later): until the copy read is the one just built, read it
	// again.
	var data []byte
	var digest string
	for attempt := 0; ; attempt++ {
		var err error
		data, err = s.clientRead(ctx, b.space, path)
		if err != nil {
			fail("the built app could not be read from the computer: " + err.Error())
			return
		}
		sum := sha256.Sum256(data)
		digest = hex.EncodeToString(sum[:])
		if look.status.SHA256 == "" || strings.EqualFold(look.status.SHA256, digest) {
			break
		}
		if attempt >= 5 {
			fail("the built app read back differs from the one built; build again")
			return
		}
		select {
		case <-ctx.Done():
			fail("the build took too long")
			return
		case <-time.After(clientReadRetry):
		}
	}
	owner := b.person
	if b.agent != "" {
		if agent := s.agentBotByName(ctx, b.space, b.agent); agent != nil {
			owner = agent.AccountID
		}
	}
	file, err := s.UploadFile(ctx, owner, b.space, b.room, b.target.Slug+".apk", apkMime, data)
	if err != nil {
		fail("the built app could not be stored: " + err.Error())
		return
	}
	rec := models.PlatformClient{FileID: file.ID.String(), Version: b.version, Size: int64(len(data)), SHA256: digest,
		AppID: b.appID, BuiltBy: b.person.String(), BuiltAt: time.Now().UTC().Format(time.RFC3339)}
	if err := s.recordClient(ctx, b.target.PlatformID, rec); err != nil {
		fail("the built app could not be recorded on the platform: " + err.Error())
		return
	}
	link := platformClientURL(b.node, b.target.Slug)
	if !b.room.IsZero() {
		caption := fmt.Sprintf("%s for Android %s is ready (%.1f MB). Anyone can install it from %s — it opens %s and wakes it wherever it is opened.",
			b.target.Name, b.version, float64(len(data))/(1<<20), link, b.target.Name)
		if err := s.PostAttachmentMessage(ctx, b.space, b.room, owner, caption, []string{file.ID.String()}); err != nil && s.L != nil {
			s.L.Warn("platform client post failed", "platform", b.target.Slug, "error", err)
		}
	}
	s.finishClientBuild(b, func(st *models.PlatformClientBuild) {
		st.State, st.Step, st.Error, st.URL, st.Size = "done", "built", "", link, int64(len(data))
	})
}

func (s *Service) finishClientBuild(b *clientBuild, fn func(*models.PlatformClientBuild)) {
	b.set(fn)
	if st := b.report(); st.State == "failed" && s.L != nil {
		s.L.Warn("platform client build failed", "platform", b.target.Slug, "error", st.Error)
	}
	select {
	case <-b.done:
	default:
		close(b.done)
	}
}
