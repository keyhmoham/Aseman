package developer

// A sub-platform's frontend: an app the agents of a space built (an Elpian or
// web App UI with its own backend, wired to the space's agents and apps),
// published by an owner or admin of the organization as what the platform's
// people open. The gateway serves it at /v1/platforms/<slug>/app/; an Aseman
// client signed in to the platform opens it as the platform's home.
//
// The platform's people are not members of the space the app was built in:
// its use of the space's agents and apps runs as, and is billed to, the
// person who published it, reaches only what the app is wired to, and names
// the platform's person on every usage record (spaces/platform_frontend.go).

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/developer/models"
)

// FrontendView is a platform's published frontend as the console shows it.
type FrontendView struct {
	App         string        `json:"app"`
	Proxy       string        `json:"proxy"`
	Space       string        `json:"space"`
	Title       string        `json:"title"`
	UI          string        `json:"ui"`
	Entry       string        `json:"entry,omitempty"`
	URL         string        `json:"url"`
	PublishedBy string        `json:"publishedBy"`
	PublishedAt string        `json:"publishedAt"`
	Wiring      models.Wiring `json:"wiring"`
}

// PlatformFrontendPath is where the gateway serves a platform's frontend.
func PlatformFrontendPath(slug string) string { return "/v1/platforms/" + slug + "/app/" }

func frontendWiring(p models.Platform) models.Wiring {
	var w models.Wiring
	if json.Unmarshal([]byte(p.FrontendWiring), &w) != nil {
		w = models.Wiring{}
	}
	if w.Agents == nil {
		w.Agents = []models.WiredAgent{}
	}
	if w.Apps == nil {
		w.Apps = []models.WiredApp{}
	}
	return w
}

func frontendView(p models.Platform) *FrontendView {
	if p.FrontendProxyID == "" {
		return nil
	}
	return &FrontendView{
		App: p.FrontendApp, Proxy: p.FrontendProxyID, Space: p.FrontendSpaceID, Title: p.FrontendTitle,
		UI: p.FrontendUI, Entry: p.FrontendEntry, URL: PlatformFrontendPath(p.Slug),
		PublishedBy: p.FrontendBy.String(), PublishedAt: stamp(p.FrontendAt), Wiring: frontendWiring(p),
	}
}

func platformFrontendOf(p models.Platform) *models.PlatformFrontend {
	return &models.PlatformFrontend{
		PlatformID: p.ID.String(), OrgID: p.OrgID.String(), Slug: p.Slug, Name: p.Name, MainAccess: p.MainAccess,
		ProxyID: p.FrontendProxyID, SpaceID: p.FrontendSpaceID, App: p.FrontendApp, Title: p.FrontendTitle,
		UI: p.FrontendUI, Entry: p.FrontendEntry, Publisher: p.FrontendBy.String(), Wiring: frontendWiring(p),
	}
}

// FrontendSpaces is the spaces namespace's side of platform frontends.
type FrontendSpaces interface {
	FrontendApps(ctx context.Context, actor identity.ID) ([]models.FrontendApp, error)
	FrontendAppFor(ctx context.Context, proxyRef string, actor identity.ID) (*models.FrontendApp, error)
}

// frontendsBridge reaches the spaces namespace through the host bridge.
type frontendsBridge struct{ s *Service }

func (b frontendsBridge) FrontendApps(ctx context.Context, actor identity.ID) ([]models.FrontendApp, error) {
	var out []models.FrontendApp
	err := bridge.Invoke(ctx, b.s.K, "spaces", "FrontendApps", []any{ctx, actor}, &out)
	return out, err
}

func (b frontendsBridge) FrontendAppFor(ctx context.Context, proxyRef string, actor identity.ID) (*models.FrontendApp, error) {
	var out *models.FrontendApp
	err := bridge.Invoke(ctx, b.s.K, "spaces", "FrontendAppFor", []any{ctx, proxyRef, actor}, &out)
	return out, err
}

func (s *Service) frontends() FrontendSpaces {
	if s.Frontends != nil {
		return s.Frontends
	}
	return frontendsBridge{s: s}
}

func canManageFrontend(sc Scope) error {
	if sc.Role != models.RoleOwner && sc.Role != models.RoleAdmin {
		return errs.Permission("only owners and admins of the organization can publish the platform's frontend")
	}
	return nil
}

// FrontendApps lists the apps the caller may publish as the platform's
// frontend: apps the agents built in spaces they belong to.
func (s *Service) FrontendApps(ctx context.Context, sc Scope, caller identity.ID) ([]models.FrontendApp, error) {
	if err := canManageFrontend(sc); err != nil {
		return nil, err
	}
	out, err := s.frontends().FrontendApps(ctx, caller)
	if err != nil {
		return nil, err
	}
	if out == nil {
		out = []models.FrontendApp{}
	}
	return out, nil
}

// PublishFrontend makes the app behind preview [proxy] the platform's
// frontend. The caller must be an owner or admin of the organization and a
// member of the app's space: the platform's use of that space's agents and
// apps runs as, and is billed to, them.
func (s *Service) PublishFrontend(ctx context.Context, sc Scope, caller identity.ID, proxyRef string) (PlatformView, error) {
	if err := canManageFrontend(sc); err != nil {
		return PlatformView{}, err
	}
	p, err := s.PlatformOfOrg(ctx, sc.Org)
	if err != nil {
		return PlatformView{}, err
	}
	if p == nil {
		return PlatformView{}, errs.NotFound("This organization has no platform yet: create it first.")
	}
	app, err := s.frontends().FrontendAppFor(ctx, strings.TrimSpace(proxyRef), caller)
	if err != nil {
		return PlatformView{}, err
	}
	if app == nil {
		return PlatformView{}, errs.NotFound("no such app")
	}
	wiring, _ := json.Marshal(app.Wiring)
	now := s.now()
	p.FrontendProxyID, p.FrontendSpaceID, p.FrontendApp = app.ProxyID, app.SpaceID, app.App
	p.FrontendTitle, p.FrontendUI, p.FrontendEntry = app.Title, app.UI, app.Entry
	p.FrontendWiring, p.FrontendBy, p.FrontendAt, p.UpdatedAt = string(wiring), caller, now, now
	if err := s.R.Update(ctx, "dev_platforms", p.ID, p); err != nil {
		return PlatformView{}, err
	}
	return platformView(*p), nil
}

// UnpublishFrontend takes the platform's frontend down.
func (s *Service) UnpublishFrontend(ctx context.Context, sc Scope) (PlatformView, error) {
	if err := canManageFrontend(sc); err != nil {
		return PlatformView{}, err
	}
	p, err := s.PlatformOfOrg(ctx, sc.Org)
	if err != nil || p == nil {
		return PlatformView{}, errs.NotFound("platform")
	}
	p.FrontendProxyID, p.FrontendSpaceID, p.FrontendApp, p.FrontendTitle = "", "", "", ""
	p.FrontendUI, p.FrontendEntry, p.FrontendWiring, p.FrontendBy = "", "", "", identity.ID{}
	p.UpdatedAt = s.now()
	if err := s.R.Update(ctx, "dev_platforms", p.ID, p); err != nil {
		return PlatformView{}, err
	}
	return platformView(*p), nil
}

// canUsePlatform reports whether [viewer] may use the platform's frontend:
// people of the platform, people of main Aseman when the platform is bridged
// to it, and the organization's own members (to try it).
func (s *Service) canUsePlatform(ctx context.Context, p *models.Platform, viewer identity.ID) bool {
	var acc account.Account
	if err := s.R.Get(ctx, "accounts", viewer, &acc); err != nil {
		return false
	}
	if acc.Kind == account.KindBot {
		return false
	}
	switch {
	case acc.PlatformID == p.ID.String():
		return true
	case acc.PlatformID == "" && p.MainAccess:
		return true
	case viewer == p.OrgID: // a personal organization's platform
		return true
	}
	m, err := s.member(ctx, p.OrgID, viewer)
	return err == nil && m.Status == models.StatusActive
}

// PlatformFrontendFor is platform [ref]'s (slug or id) published frontend, for
// the gateway and the spaces namespace. A non-zero [viewer] must be someone
// who may use the platform; a zero viewer is a visitor who has not signed in.
func (s *Service) PlatformFrontendFor(ctx context.Context, ref string, viewer identity.ID) (*models.PlatformFrontend, error) {
	p, err := s.PlatformByRef(ctx, ref)
	if err != nil {
		return nil, err
	}
	if p.FrontendProxyID == "" {
		return nil, errs.NotFound(p.Name + " has not published a frontend yet")
	}
	if !viewer.IsZero() && !s.canUsePlatform(ctx, p, viewer) {
		return nil, errs.Permission("this account is not on " + p.Name + ": sign in with an account of this platform")
	}
	return platformFrontendOf(*p), nil
}

// PublicFrontend is what a client needs to open a platform before anyone
// signs in: its name and, when it has one, its frontend.
func (s *Service) PublicFrontend(ctx context.Context, ref string) (map[string]any, error) {
	p, err := s.PlatformByRef(ctx, ref)
	if err != nil {
		return nil, err
	}
	out := map[string]any{"platform": map[string]any{"id": p.ID.String(), "slug": p.Slug, "name": p.Name}, "frontend": nil}
	if p.FrontendProxyID != "" {
		out["frontend"] = map[string]any{
			"title": p.FrontendTitle, "ui": p.FrontendUI, "entry": p.FrontendEntry, "url": PlatformFrontendPath(p.Slug),
		}
	}
	return out, nil
}
