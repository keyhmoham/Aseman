package developer

// What a person's agents may do on the developer surface for them, through
// three narrow tools of the spaces namespace (platform_setup,
// app_developer_access, platform_publish). The developer namespace itself
// stays closed to agents (pkg/agentpolicy): these methods act only as the
// person whose request the agent's turn serves, never as the agent, and only
// within that person's own organizations and roles.

import (
	"context"
	"strings"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/developer/models"
)

// PlatformSetup is what platform_setup answers.
type PlatformSetup struct {
	Org      OrgView      `json:"org"`
	Platform PlatformView `json:"platform"`
	// Created says what was made now (false: it existed and is reused).
	OrgCreated      bool `json:"org_created"`
	PlatformCreated bool `json:"platform_created"`
}

// requirePerson refuses anyone but an active person.
func (s *Service) requirePerson(ctx context.Context, person identity.ID) error {
	if person.IsZero() {
		return errs.Permission("there is no person to act for: only a person's own request can set up their organization")
	}
	var acc account.Account
	if err := s.R.Get(ctx, "accounts", person, &acc); err != nil {
		return errs.Permission("the person is unknown")
	}
	if acc.Kind == account.KindBot {
		return errs.Permission("organizations belong to people, not agents")
	}
	return nil
}

func orgViewOf(sc Scope) OrgView {
	if sc.Personal {
		return OrgView{ID: PersonalOrg, Name: "Personal", Kind: "personal", Role: sc.Role}
	}
	return OrgView{ID: sc.Org.String(), Name: sc.Name, Kind: "team", Role: sc.Role}
}

// SetupPlatform gives [person] an organization with a sub-platform: the
// organization [orgRef] names ("personal" or a team's id), or a team
// organization called [orgName] (made when they have none by that name), or
// their personal one. The platform is made unless the organization has one.
func (s *Service) SetupPlatform(ctx context.Context, person identity.ID, orgRef, orgName, name, slug string) (PlatformSetup, error) {
	if err := s.requirePerson(ctx, person); err != nil {
		return PlatformSetup{}, err
	}
	out := PlatformSetup{}
	orgRef, orgName = strings.TrimSpace(orgRef), strings.TrimSpace(orgName)
	if orgRef == "" && orgName != "" {
		orgs, err := s.Orgs(ctx, person)
		if err != nil {
			return PlatformSetup{}, err
		}
		for _, o := range orgs {
			if o.Kind == "team" && strings.EqualFold(o.Name, orgName) {
				orgRef = o.ID
			}
		}
		if orgRef == "" {
			made, err := s.CreateOrg(ctx, person, orgName)
			if err != nil {
				return PlatformSetup{}, err
			}
			orgRef, out.OrgCreated = made.ID, true
		}
	}
	sc, err := s.Scope(ctx, person, orgRef)
	if err != nil {
		return PlatformSetup{}, err
	}
	out.Org = orgViewOf(sc)
	existing, err := s.PlatformOfOrg(ctx, sc.Org)
	if err != nil {
		return PlatformSetup{}, err
	}
	if existing != nil {
		out.Platform = platformView(*existing)
		return out, nil
	}
	if strings.TrimSpace(name) == "" {
		name = sc.Name
	}
	view, err := s.CreatePlatform(ctx, sc, name, slug)
	if err != nil {
		return PlatformSetup{}, err
	}
	out.Platform, out.PlatformCreated = view, true
	return out, nil
}

// platformScope is the organization whose platform [person] means: the one
// [orgRef] names, else the only one of theirs that has a platform they may
// manage.
func (s *Service) platformScope(ctx context.Context, person identity.ID, orgRef string) (Scope, *models.Platform, error) {
	if strings.TrimSpace(orgRef) != "" {
		sc, err := s.Scope(ctx, person, orgRef)
		if err != nil {
			return Scope{}, nil, err
		}
		p, err := s.PlatformOfOrg(ctx, sc.Org)
		if err != nil {
			return Scope{}, nil, err
		}
		if p == nil {
			return Scope{}, nil, errs.NotFound(sc.Name + " has no platform yet: set one up first (platform_setup)")
		}
		return sc, p, nil
	}
	orgs, err := s.Orgs(ctx, person)
	if err != nil {
		return Scope{}, nil, err
	}
	var found []Scope
	var platforms []*models.Platform
	for _, o := range orgs {
		sc, err := s.Scope(ctx, person, o.ID)
		if err != nil || (sc.Role != models.RoleOwner && sc.Role != models.RoleAdmin) {
			continue
		}
		if p, err := s.PlatformOfOrg(ctx, sc.Org); err == nil && p != nil {
			found, platforms = append(found, sc), append(platforms, p)
		}
	}
	switch len(found) {
	case 0:
		return Scope{}, nil, errs.NotFound("the person has no platform yet: set one up first (platform_setup)")
	case 1:
		return found[0], platforms[0], nil
	}
	names := make([]string, 0, len(found))
	for i, sc := range found {
		names = append(names, orgViewOf(sc).ID+" ("+platforms[i].Slug+")")
	}
	return Scope{}, nil, errs.InvalidArgument("the person has several platforms; name the organization (org): " + strings.Join(names, ", "))
}

// AppDeveloperKey makes a developer API key of [person]'s organization for
// one app's server ([appName]): models to list, chat to write, and, with
// [platformAPI], the platform collection to write. It acts as the person.
// [replace] (an earlier key of the same app) is revoked first.
func (s *Service) AppDeveloperKey(ctx context.Context, person identity.ID, orgRef, appName string, platformAPI bool, replace string) (models.AppAccess, error) {
	if err := s.requirePerson(ctx, person); err != nil {
		return models.AppAccess{}, err
	}
	var sc Scope
	platform := ""
	if p, err := func() (*models.Platform, error) {
		var p *models.Platform
		var err error
		sc, p, err = s.platformScope(ctx, person, orgRef)
		return p, err
	}(); err == nil {
		platform = p.Slug
	} else {
		// No platform: the key is still the organization's (personal by default).
		var serr error
		if sc, serr = s.Scope(ctx, person, orgRef); serr != nil {
			return models.AppAccess{}, serr
		}
	}
	if err := sc.Require("keys"); err != nil {
		return models.AppAccess{}, err
	}
	if replace = strings.TrimSpace(replace); replace != "" {
		_ = s.RevokeKey(ctx, sc, replace)
	}
	perms := Permissions{Models: LevelRead, Chat: LevelWrite, Usage: LevelRead}
	if platformAPI {
		perms.Platform = LevelWrite
	}
	name := strings.TrimSpace(appName)
	if name == "" {
		name = "app"
	}
	if len([]rune(name)) > 50 {
		name = string([]rune(name)[:50])
	}
	view, secret, err := s.CreateKey(ctx, person, sc, KeyInput{Name: "App · " + name, Permissions: perms})
	if err != nil {
		return models.AppAccess{}, err
	}
	return models.AppAccess{KeyID: view.ID, Secret: secret, Org: orgViewOf(sc).ID, Platform: platform}, nil
}

// PublishFrontendAs publishes the app behind preview [proxyRef] as the
// frontend of [person]'s platform (in [orgRef], or their only one).
func (s *Service) PublishFrontendAs(ctx context.Context, person identity.ID, orgRef, proxyRef string) (PlatformView, error) {
	if err := s.requirePerson(ctx, person); err != nil {
		return PlatformView{}, err
	}
	sc, _, err := s.platformScope(ctx, person, orgRef)
	if err != nil {
		return PlatformView{}, err
	}
	return s.PublishFrontend(ctx, sc, person, proxyRef)
}
