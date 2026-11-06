package spaces

// Platform frontends. An app the agents of a space built and published with
// appui_publish (an Elpian or web App UI with its own backend) can be
// published by an owner or admin of a developer organization as the frontend
// of the organization's platform (developer/platform_frontend.go). The
// gateway then serves it to the platform's people at /v1/platforms/<slug>/app/.
//
// The platform's people are not members of the space, so the app reaches the
// space for them as the person who published it:
//
//   - the gateway hands the app's server a platform user token with each
//     request (X-Aseman-User-Token, as for any app). With it — and from the
//     page's own _aseman/api — the app's calls run as, and are billed to, the
//     publisher (who must still be a member of the space), on behalf of the
//     platform's person, whose name is on every usage record;
//   - they reach exactly the agents and apps the app was built against (its
//     wiring, read from APPS.json when it was published), nothing else of
//     the space.

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// App audiences: who an App UI is built for.
const (
	appuiAudienceSpace    = "space"
	appuiAudiencePlatform = "platform"
)

// appuiAudience picks who an App UI is built for: the space's own people
// (the default) or a platform's people, as that platform's frontend.
func appuiAudience(asked, existing string) (string, error) {
	switch a := strings.ToLower(strings.TrimSpace(asked)); a {
	case appuiAudienceSpace, appuiAudiencePlatform:
		return a, nil
	case "":
		if existing == appuiAudiencePlatform {
			return appuiAudiencePlatform, nil
		}
		return appuiAudienceSpace, nil
	default:
		return "", errs.InvalidArgument(`audience is "space" (the default: people of this space) or "platform" (the frontend of a platform the person runs, used by that platform's people)`)
	}
}

// parseWiring reads an app's APPS.json into the agents and apps it is wired to.
func parseWiring(raw string) models.Wiring {
	var doc struct {
		Apps []struct {
			BotID       string `json:"bot_id"`
			Name        string `json:"name"`
			DisplayName string `json:"display_name"`
			Microtools []struct {
				Name string `json:"name"`
			} `json:"microtools"`
		} `json:"apps"`
		Agents []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"agents"`
	}
	w := models.Wiring{Agents: []models.WiredAgent{}, Apps: []models.WiredApp{}}
	if json.Unmarshal([]byte(raw), &doc) != nil {
		return w
	}
	for _, a := range doc.Agents {
		if strings.TrimSpace(a.ID) == "" && strings.TrimSpace(a.Name) == "" {
			continue
		}
		w.Agents = append(w.Agents, models.WiredAgent{ID: a.ID, Name: a.Name})
	}
	for _, a := range doc.Apps {
		if strings.TrimSpace(a.BotID) == "" && strings.TrimSpace(a.Name) == "" {
			continue
		}
		app := models.WiredApp{ID: a.BotID, Name: a.Name, DisplayName: a.DisplayName}
		for _, m := range a.Microtools {
			if m.Name != "" {
				app.Microtools = append(app.Microtools, m.Name)
			}
		}
		w.Apps = append(w.Apps, app)
	}
	return w
}

// appKeyMetaFor is what appui_publish records with an app's key: what the
// app is and what it is wired to (its APPS.json, read from the computer the
// app was just verified on).
func (s *Service) appKeyMetaFor(ctx context.Context, spaceID identity.ID, job appuiJob, entry string) appKeyMeta {
	raw, _ := s.sandboxReadText(ctx, spaceID, job.Dir+"/APPS.json")
	wiring, _ := json.Marshal(parseWiring(raw))
	audience := job.Audience
	if audience == "" {
		audience = appuiAudienceSpace
	}
	return appKeyMeta{UI: job.UI, Entry: entry, Kind: job.Kind, Audience: audience, Wiring: string(wiring)}
}

func frontendAppOf(k AppKey, spaceName string) models.FrontendApp {
	var w models.Wiring
	if json.Unmarshal([]byte(k.Wiring), &w) != nil {
		w = models.Wiring{}
	}
	if w.Agents == nil {
		w.Agents = []models.WiredAgent{}
	}
	if w.Apps == nil {
		w.Apps = []models.WiredApp{}
	}
	ui := k.UI
	if ui == "" {
		ui = appuiWeb
	}
	return models.FrontendApp{
		ProxyID: k.ProxyID, SpaceID: k.SpaceID.String(), SpaceName: spaceName, App: k.AppID,
		Title: k.Title, UI: ui, Entry: k.Entry, Kind: k.Kind, Audience: k.Audience, Wiring: w,
		UpdatedAt: k.UpdatedAt.UTC().Format(time.RFC3339),
	}
}

// FrontendApps lists the apps [actor] may publish as a platform's frontend:
// apps the agents built and published (framed apps, not gadgets) in the
// spaces they are a member of. Apps built for a platform come first.
func (s *Service) FrontendApps(ctx context.Context, actor identity.ID) ([]models.FrontendApp, error) {
	if actor.IsZero() {
		return nil, errs.Unauthenticated("authentication required")
	}
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{Equal: map[string]any{"member_id": actor.String()}}, &mems); err != nil {
		return nil, err
	}
	seen := map[identity.ID]bool{}
	out := []models.FrontendApp{}
	for _, m := range mems {
		if seen[m.SpaceID] {
			continue
		}
		seen[m.SpaceID] = true
		var keys []AppKey
		if err := s.R.List(ctx, "app_keys", database.Filter{Equal: map[string]any{"space_id": m.SpaceID.String()}}, &keys); err != nil {
			return nil, err
		}
		name := ""
		if sp, err := s.GetSpace(ctx, m.SpaceID); err == nil && sp != nil {
			name = sp.Name
		}
		for _, k := range keys {
			if k.ProxyID == "" || k.Kind == appuiKindGadget {
				continue
			}
			pid, err := identity.Parse(k.ProxyID)
			if err != nil {
				continue
			}
			if _, err := s.ProxyGet(ctx, pid); err != nil {
				continue // its preview was deleted
			}
			out = append(out, frontendAppOf(k, name))
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		pi, pj := out[i].Audience == appuiAudiencePlatform, out[j].Audience == appuiAudiencePlatform
		if pi != pj {
			return pi
		}
		return out[i].UpdatedAt > out[j].UpdatedAt
	})
	return out, nil
}

// FrontendAppFor checks that [actor] may publish the app behind preview
// [proxyRef] as a platform's frontend, and describes it.
func (s *Service) FrontendAppFor(ctx context.Context, proxyRef string, actor identity.ID) (*models.FrontendApp, error) {
	id, err := identity.Parse(strings.TrimSpace(proxyRef))
	if err != nil {
		return nil, errs.InvalidArgument("name the app by its preview id (proxy)")
	}
	if actor.IsZero() || s.isBotAccount(ctx, actor) {
		return nil, errs.Permission("a person publishes a platform's frontend")
	}
	p, err := s.ProxyGet(ctx, id)
	if err != nil {
		return nil, errs.NotFound("no such app")
	}
	if _, err := s.SpaceMembership(ctx, p.SpaceID, actor); err != nil {
		return nil, errs.Permission("you can publish only apps of spaces you are a member of")
	}
	var keys []AppKey
	if err := s.R.List(ctx, "app_keys", database.Filter{Equal: map[string]any{"proxy_id": id.String()}, Limit: 1}, &keys); err != nil {
		return nil, err
	}
	if len(keys) == 0 {
		return nil, errs.InvalidArgument("only an app the space's agents built and published (appui_create, then appui_publish) can be a platform's frontend: it carries its backend and its wiring to the space's agents and apps")
	}
	if keys[0].Kind == appuiKindGadget {
		return nil, errs.InvalidArgument("a gadget cannot be a platform's frontend; ask the agents for an app (kind app, audience platform)")
	}
	name := ""
	if sp, err := s.GetSpace(ctx, p.SpaceID); err == nil && sp != nil {
		name = sp.Name
	}
	app := frontendAppOf(keys[0], name)
	return &app, nil
}

// PlatformUserToken is the token the gateway hands a platform frontend's
// server with each request of [viewer], a person of platform [platformID]:
// the server reaches the space's agents and apps for them with it, as the
// frontend's publisher.
func (s *Service) PlatformUserToken(p *proxy.Proxy, viewer identity.ID, platformID string) (string, error) {
	if strings.TrimSpace(platformID) == "" {
		return "", errs.InvalidArgument("platform required")
	}
	return s.signAppClaims(appUserClaims{Proxy: p.ID.String(), User: viewer.String(), Platform: platformID,
		Exp: time.Now().Add(appUserTokenTTL).Unix()})
}

// platformFrontendFor asks the developer namespace for platform [ref]'s
// published frontend, as [viewer] may use it.
func (s *Service) platformFrontendFor(ctx context.Context, ref string, viewer identity.ID) (*models.PlatformFrontend, error) {
	if s.frontendLookup != nil {
		return s.frontendLookup(ctx, ref, viewer)
	}
	var out *models.PlatformFrontend
	if err := bridge.Invoke(ctx, s.K, "developer", "PlatformFrontendFor", []any{ctx, ref, viewer}, &out); err != nil {
		return nil, err
	}
	if out == nil {
		return nil, errs.NotFound("platform frontend")
	}
	return out, nil
}

// platformAppCaller resolves a platform user token: the call runs as the
// frontend's publisher for the platform's person, while the app is still
// that platform's frontend and the person may still use the platform.
func (s *Service) platformAppCaller(ctx context.Context, claims appUserClaims) (*proxy.Access, error) {
	user, err := identity.Parse(claims.User)
	if err != nil {
		return nil, errs.Unauthenticated("invalid app user token")
	}
	pf, err := s.platformFrontendFor(ctx, claims.Platform, user)
	if err != nil {
		return nil, err
	}
	if pf.ProxyID != claims.Proxy {
		return nil, errs.Unauthenticated("this app is no longer the platform's frontend")
	}
	pid, err := identity.Parse(pf.ProxyID)
	if err != nil {
		return nil, errs.Unauthenticated("invalid app user token")
	}
	p, err := s.ProxyGet(ctx, pid)
	if err != nil {
		return nil, errs.Unauthenticated("the platform's frontend app was deleted")
	}
	var person account.Account
	if err := s.R.Get(ctx, "accounts", user, &person); err != nil {
		return nil, errs.Unauthenticated("the person this app serves is unknown")
	}
	if person.Kind == account.KindBot || person.Status != account.StatusActive {
		return nil, errs.Permission("the person this app serves cannot use it")
	}
	publisher, err := identity.Parse(pf.Publisher)
	if err != nil {
		return nil, errs.Permission("the platform's frontend has no publisher")
	}
	if _, err := s.SpaceMembership(ctx, p.SpaceID, publisher); err != nil {
		return nil, errs.Permission("the person who published this platform's frontend is no longer a member of its space; publish it again")
	}
	var payer account.Account
	if err := s.R.Get(ctx, "accounts", publisher, &payer); err != nil {
		return nil, errs.Permission("the person who published this platform's frontend is unknown")
	}
	if payer.Kind == account.KindBot || payer.Status != account.StatusActive {
		return nil, errs.Permission("the person who published this platform's frontend cannot be billed")
	}
	name := pf.Name
	if name == "" {
		name = pf.Slug
	}
	via := "platform " + name + " · app " + p.Title + " for @" + person.Handle
	return &proxy.Access{Proxy: p, Payer: &payer, Via: via, Platform: pf, User: &person}, nil
}
