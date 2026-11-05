package developer

import (
	"context"
	"regexp"
	"strings"
	"unicode"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/tenancy"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

var platformSlug = regexp.MustCompile(`^[a-z][a-z0-9-]{1,47}$`)

// PlatformView is a platform as the console and APIs show it.
type PlatformView struct {
	ID         string `json:"id"`
	Org        string `json:"org"`
	Slug       string `json:"slug"`
	Name       string `json:"name"`
	MainAccess bool   `json:"mainAccess"`
	CreatedAt  string `json:"createdAt"`
}

func platformView(p models.Platform) PlatformView {
	return PlatformView{
		ID: p.ID.String(), Org: p.OrgID.String(), Slug: p.Slug, Name: p.Name,
		MainAccess: p.MainAccess, CreatedAt: stamp(p.CreatedAt),
	}
}

func cleanPlatformSlug(slug string) (string, error) {
	slug = strings.ToLower(strings.TrimSpace(slug))
	if !platformSlug.MatchString(slug) {
		return "", errs.InvalidArgument("A platform slug is 2–48 characters: start with a letter, then letters, digits or hyphens.")
	}
	switch slug {
	case "main", "aseman", "admin", "api", "www", "app":
		return "", errs.InvalidArgument("That slug is reserved.")
	}
	return slug, nil
}

func cleanPlatformName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", errs.InvalidArgument("A platform needs a name.")
	}
	runes := []rune(name)
	if len(runes) > 80 {
		return "", errs.InvalidArgument("A platform's name can be up to 80 characters.")
	}
	for _, r := range runes {
		if unicode.IsControl(r) {
			return "", errs.InvalidArgument("A platform's name cannot contain control characters.")
		}
	}
	return name, nil
}

// PlatformOfOrg returns the platform owned by an organization, if any.
func (s *Service) PlatformOfOrg(ctx context.Context, org identity.ID) (*models.Platform, error) {
	var list []models.Platform
	if err := s.R.List(ctx, "dev_platforms", database.Filter{Equal: map[string]any{"org_id": org.String()}, Limit: 1}, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, nil
	}
	return &list[0], nil
}

// PlatformByRef finds a platform by id or slug.
func (s *Service) PlatformByRef(ctx context.Context, ref string) (*models.Platform, error) {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return nil, errs.NotFound("platform")
	}
	if id, err := identity.Parse(ref); err == nil {
		var p models.Platform
		if err := s.R.Get(ctx, "dev_platforms", id, &p); err == nil {
			return &p, nil
		}
	}
	var list []models.Platform
	if err := s.R.List(ctx, "dev_platforms", database.Filter{Equal: map[string]any{"slug": strings.ToLower(ref)}, Limit: 1}, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, errs.NotFound("platform")
	}
	return &list[0], nil
}

// CreatePlatform makes a sub-platform for an organization. One per org.
func (s *Service) CreatePlatform(ctx context.Context, sc Scope, name, slug string) (PlatformView, error) {
	if sc.Role != models.RoleOwner && sc.Role != models.RoleAdmin {
		return PlatformView{}, errs.Permission("only owners and admins of the organization can create a platform")
	}
	if existing, err := s.PlatformOfOrg(ctx, sc.Org); err != nil {
		return PlatformView{}, err
	} else if existing != nil {
		return PlatformView{}, errs.AlreadyExists("This organization already has a platform.")
	}
	name, err := cleanPlatformName(name)
	if err != nil {
		return PlatformView{}, err
	}
	slug, err = cleanPlatformSlug(slug)
	if err != nil {
		return PlatformView{}, err
	}
	var taken []models.Platform
	if err := s.R.List(ctx, "dev_platforms", database.Filter{Equal: map[string]any{"slug": slug}, Limit: 1}, &taken); err != nil {
		return PlatformView{}, err
	}
	if len(taken) > 0 {
		return PlatformView{}, errs.AlreadyExists("slug " + slug)
	}
	id, err := s.newID()
	if err != nil {
		return PlatformView{}, err
	}
	now := s.now()
	p := &models.Platform{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		OrgID: sc.Org, Slug: slug, Name: name}
	if err := s.R.CreateID(ctx, "dev_platforms", id, p); err != nil {
		return PlatformView{}, err
	}
	return platformView(*p), nil
}

// RenamePlatform changes the display name (not the slug).
func (s *Service) RenamePlatform(ctx context.Context, sc Scope, name string) (PlatformView, error) {
	if sc.Role != models.RoleOwner && sc.Role != models.RoleAdmin {
		return PlatformView{}, errs.Permission("only owners and admins can rename the platform")
	}
	p, err := s.PlatformOfOrg(ctx, sc.Org)
	if err != nil || p == nil {
		return PlatformView{}, errs.NotFound("platform")
	}
	name, err = cleanPlatformName(name)
	if err != nil {
		return PlatformView{}, err
	}
	p.Name, p.UpdatedAt = name, s.now()
	if err := s.R.Update(ctx, "dev_platforms", p.ID, p); err != nil {
		return PlatformView{}, err
	}
	return platformView(*p), nil
}

// DeletePlatform removes the platform record. Existing accounts/spaces stamped
// with its id stay, but new signups and discovery treat it as gone.
func (s *Service) DeletePlatform(ctx context.Context, sc Scope) error {
	if sc.Role != models.RoleOwner {
		return errs.Permission("only the owner can delete the platform")
	}
	p, err := s.PlatformOfOrg(ctx, sc.Org)
	if err != nil || p == nil {
		return errs.NotFound("platform")
	}
	return s.R.Delete(ctx, "dev_platforms", p.ID)
}

// SetMainAccess is the node admin's boolean bridge between a platform and main Aseman.
func (s *Service) SetMainAccess(ctx context.Context, ref string, access bool) (PlatformView, error) {
	p, err := s.PlatformByRef(ctx, ref)
	if err != nil {
		return PlatformView{}, err
	}
	p.MainAccess, p.UpdatedAt = access, s.now()
	if err := s.R.Update(ctx, "dev_platforms", p.ID, p); err != nil {
		return PlatformView{}, err
	}
	return platformView(*p), nil
}

// PlatformUsers lists people whose accounts belong to this platform.
func (s *Service) PlatformUsers(ctx context.Context, sc Scope, query string, limit int) ([]map[string]any, error) {
	if sc.Role != models.RoleOwner && sc.Role != models.RoleAdmin && sc.Role != models.RoleDeveloper {
		return nil, errs.Permission("your role cannot list platform users")
	}
	p, err := s.PlatformOfOrg(ctx, sc.Org)
	if err != nil || p == nil {
		return nil, errs.NotFound("platform")
	}
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	var list []account.Account
	if err := s.R.List(ctx, "accounts", database.Filter{
		Equal: map[string]any{"platform_id": p.ID.String(), "kind": string(account.KindUser)},
		Limit: limit, OrderBy: "created_at", Asc: false,
	}, &list); err != nil {
		return nil, err
	}
	q := strings.ToLower(strings.TrimSpace(query))
	out := make([]map[string]any, 0, len(list))
	for _, a := range list {
		if q != "" && !strings.Contains(strings.ToLower(a.Handle), q) && !strings.Contains(strings.ToLower(a.Email), q) {
			continue
		}
		out = append(out, map[string]any{
			"id": a.ID.String(), "handle": a.Handle, "email": a.Email,
			"status": a.Status, "created_at": stamp(a.CreatedAt),
		})
	}
	return out, nil
}

// PlatformStats is a short overview for the sub-platform admin console.
func (s *Service) PlatformStats(ctx context.Context, sc Scope) (map[string]any, error) {
	p, err := s.PlatformOfOrg(ctx, sc.Org)
	if err != nil || p == nil {
		return nil, errs.NotFound("platform")
	}
	var users []account.Account
	_ = s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"platform_id": p.ID.String(), "kind": string(account.KindUser)}}, &users)
	var spaces []struct {
		ID string `db:"id"`
	}
	_ = s.R.List(ctx, "spaces", database.Filter{Equal: map[string]any{"platform_id": p.ID.String()}}, &spaces)
	var bots []struct {
		ID string `db:"id"`
	}
	_ = s.R.List(ctx, "bots", database.Filter{Equal: map[string]any{"platform_id": p.ID.String()}}, &bots)
	return map[string]any{
		"platform": platformView(*p),
		"users":    len(users),
		"spaces":   len(spaces),
		"bots":     len(bots),
		"main":     tenancy.Main,
	}, nil
}

// AdminPlatforms lists every platform for the node admin.
func (s *Service) AdminPlatforms(ctx context.Context) ([]PlatformView, error) {
	var list []models.Platform
	if err := s.R.List(ctx, "dev_platforms", database.Filter{OrderBy: "created_at", Asc: false}, &list); err != nil {
		return nil, err
	}
	out := make([]PlatformView, 0, len(list))
	for _, p := range list {
		out = append(out, platformView(p))
	}
	return out, nil
}
