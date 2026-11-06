package developer

// A platform's own Android app: the lightweight Elpian client
// (app/platform_client) built for the platform's published Elpian frontend.
// The spaces namespace builds it on the frontend space's computer
// (spaces/platform_client.go) and stores the APK as a file of that space;
// this namespace records it on the platform, and anyone downloads it at
// /v1/platforms/<slug>/client/android.apk. Whoever opens it, wherever, wakes
// the platform's computer (the gateway's _aseman/wake).

import (
	"context"
	"os"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/developer/models"
)

// PlatformClientPath is where anyone downloads a platform's Android client.
func PlatformClientPath(slug string) string { return "/v1/platforms/" + slug + "/client/android.apk" }

// ClientView is a platform's Android client as the console and the public
// description show it.
type ClientView struct {
	URL     string `json:"url"`
	Version string `json:"version"`
	Size    int64  `json:"size"`
	SHA256  string `json:"sha256"`
	AppID   string `json:"appId"`
	// Godot: the app carries the embedded Godot engine (3D scenes).
	Godot   bool   `json:"godot"`
	BuiltAt string `json:"builtAt"`
}

func clientView(p models.Platform) *ClientView {
	if p.ClientFileID == "" {
		return nil
	}
	return &ClientView{URL: PlatformClientPath(p.Slug), Version: p.ClientVersion, Size: p.ClientSize,
		SHA256: p.ClientSHA256, AppID: p.ClientAppID, Godot: p.ClientGodot, BuiltAt: stamp(p.ClientAt)}
}

func platformClientOf(p models.Platform) *models.PlatformClient {
	if p.ClientFileID == "" {
		return nil
	}
	return &models.PlatformClient{FileID: p.ClientFileID, Version: p.ClientVersion, Size: p.ClientSize, SHA256: p.ClientSHA256,
		AppID: p.ClientAppID, Godot: p.ClientGodot, BuiltBy: p.ClientBy.String(), BuiltAt: stamp(p.ClientAt)}
}

func clientTargetOf(p models.Platform) *models.PlatformClientTarget {
	return &models.PlatformClientTarget{
		PlatformID: p.ID.String(), Slug: p.Slug, Name: p.Name,
		ProxyID: p.FrontendProxyID, SpaceID: p.FrontendSpaceID, UI: p.FrontendUI, Entry: p.FrontendEntry, Title: p.FrontendTitle,
		Client: platformClientOf(p),
	}
}

// PlatformClientTarget is [person]'s platform [platformRef] (or the only one
// in [orgRef], or their only one) as building its client needs it. Only an
// owner or admin of its organization builds the platform's app.
func (s *Service) PlatformClientTarget(ctx context.Context, person identity.ID, orgRef, platformRef string) (*models.PlatformClientTarget, error) {
	if err := s.requirePerson(ctx, person); err != nil {
		return nil, err
	}
	sc, p, err := s.platformScope(ctx, person, orgRef, platformRef)
	if err != nil {
		return nil, err
	}
	if err := canManageFrontend(sc); err != nil {
		return nil, errs.Permission("only owners and admins of the organization can build the platform's app")
	}
	return clientTargetOf(*p), nil
}

// RecordPlatformClient records [c] as platform [platformID]'s Android client
// (the spaces namespace, once a build stored its APK).
func (s *Service) RecordPlatformClient(ctx context.Context, platformID string, c models.PlatformClient) error {
	id, err := identity.Parse(strings.TrimSpace(platformID))
	if err != nil {
		return errs.InvalidArgument("platform id")
	}
	var p models.Platform
	if err := s.R.Get(ctx, "dev_platforms", id, &p); err != nil {
		return errs.NotFound("platform")
	}
	if strings.TrimSpace(c.FileID) == "" {
		return errs.InvalidArgument("the client's file")
	}
	by, _ := identity.Parse(c.BuiltBy)
	now := s.now()
	p.ClientFileID, p.ClientVersion, p.ClientSize, p.ClientSHA256 = c.FileID, c.Version, c.Size, c.SHA256
	p.ClientAppID, p.ClientGodot, p.ClientBy, p.ClientAt, p.UpdatedAt = c.AppID, c.Godot, by, now, now
	return s.R.Update(ctx, "dev_platforms", p.ID, &p)
}

// PlatformClientFile is the Android client of platform [ref] (slug or id),
// for anyone to download.
func (s *Service) PlatformClientFile(ctx context.Context, ref string) (*models.PlatformClient, error) {
	p, err := s.PlatformByRef(ctx, ref)
	if err != nil {
		return nil, err
	}
	c := platformClientOf(*p)
	if c == nil {
		return nil, errs.NotFound(p.Name + " has no Android app yet")
	}
	return c, nil
}

// ClientSpaces is the spaces namespace's side of platform clients.
type ClientSpaces interface {
	StartPlatformClientBuild(ctx context.Context, person identity.ID, target models.PlatformClientTarget, opts models.PlatformClientOptions) (models.PlatformClientBuild, error)
	PlatformClientBuildStatus(ctx context.Context, person identity.ID, target models.PlatformClientTarget) (models.PlatformClientBuild, error)
}

type clientsBridge struct{ s *Service }

func (b clientsBridge) StartPlatformClientBuild(ctx context.Context, person identity.ID, target models.PlatformClientTarget, opts models.PlatformClientOptions) (models.PlatformClientBuild, error) {
	var out models.PlatformClientBuild
	err := bridge.Invoke(ctx, b.s.K, "spaces", "StartPlatformClientBuild", []any{ctx, person, target, opts}, &out)
	return out, err
}

func (b clientsBridge) PlatformClientBuildStatus(ctx context.Context, person identity.ID, target models.PlatformClientTarget) (models.PlatformClientBuild, error) {
	var out models.PlatformClientBuild
	err := bridge.Invoke(ctx, b.s.K, "spaces", "PlatformClientBuildStatus", []any{ctx, person, target}, &out)
	return out, err
}

func (s *Service) clients() ClientSpaces {
	if s.Clients != nil {
		return s.Clients
	}
	return clientsBridge{s: s}
}

// BuildPlatformClient starts building platform [ref]'s Android client on its
// frontend space's computer (the console's Build button), as [caller].
func (s *Service) BuildPlatformClient(ctx context.Context, sc Scope, caller identity.ID, ref string, opts models.PlatformClientOptions) (models.PlatformClientBuild, error) {
	if err := canManageFrontend(sc); err != nil {
		return models.PlatformClientBuild{}, err
	}
	p, err := s.mustOrgPlatform(ctx, sc.Org, ref)
	if err != nil {
		return models.PlatformClientBuild{}, err
	}
	return s.clients().StartPlatformClientBuild(ctx, caller, *clientTargetOf(*p), opts)
}

// PlatformClientStatus is how the latest build of platform [ref]'s client stands.
func (s *Service) PlatformClientStatus(ctx context.Context, sc Scope, caller identity.ID, ref string) (models.PlatformClientBuild, error) {
	if err := canManageFrontend(sc); err != nil {
		return models.PlatformClientBuild{}, err
	}
	p, err := s.mustOrgPlatform(ctx, sc.Org, ref)
	if err != nil {
		return models.PlatformClientBuild{}, err
	}
	return s.clients().PlatformClientBuildStatus(ctx, caller, *clientTargetOf(*p))
}

// autoBuildClient starts a build of the platform's Android client after its
// Elpian frontend was published from the console. It is best effort: the
// frontend is published whatever happens, and the console shows the build.
func (s *Service) autoBuildClient(caller identity.ID, view PlatformView) {
	if view.Frontend == nil || view.Frontend.UI == "web" || os.Getenv("ASEMAN_PLATFORM_CLIENT_AUTOBUILD") == "0" {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()
		p, err := s.PlatformByRef(ctx, view.ID)
		if err != nil {
			return
		}
		if _, err := s.clients().StartPlatformClientBuild(ctx, caller, *clientTargetOf(*p), models.PlatformClientOptions{}); err != nil && s.L != nil {
			s.L.Warn("platform client build did not start", "platform", p.Slug, "error", err)
		}
	}()
}
