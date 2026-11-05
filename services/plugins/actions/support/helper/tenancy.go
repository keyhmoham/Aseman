package helper

import (
	"context"
	"strings"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/tenancy"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

type platformCtxKey struct{}

// WithPlatform stamps the request context with the environment new entities
// should join (developer API calls for an org that owns a sub-platform).
func WithPlatform(ctx context.Context, platformID string) context.Context {
	return context.WithValue(ctx, platformCtxKey{}, platformID)
}

// ContextPlatform is the explicit environment from WithPlatform, if any.
func ContextPlatform(ctx context.Context) (string, bool) {
	v, ok := ctx.Value(platformCtxKey{}).(string)
	return v, ok
}

// EntityPlatform is where a new space/bot should live: an explicit developer
// API platform stamp, else the caller's account home.
func EntityPlatform(ctx context.Context, r *repo.Repo, owner identity.ID) string {
	if pid, ok := ContextPlatform(ctx); ok {
		return pid
	}
	return AccountPlatform(ctx, r, owner)
}

// platformRow is the slice of a developer platform we need for visibility.
type platformRow struct {
	ID         string `db:"id"`
	MainAccess bool   `db:"main_access"`
	Slug       string `db:"slug"`
}

// BridgedPlatforms returns platform ids the node admin has opened onto main Aseman.
func BridgedPlatforms(ctx context.Context, r *repo.Repo) (map[string]bool, error) {
	out := map[string]bool{}
	if r == nil || r.DB == nil {
		return out, nil
	}
	var list []platformRow
	if err := r.List(ctx, "dev_platforms", database.Filter{Equal: map[string]any{"main_access": true}}, &list); err != nil {
		// Table may not exist yet on older nodes mid-migration.
		return out, nil
	}
	for _, p := range list {
		out[p.ID] = true
	}
	return out, nil
}

// AccountPlatform is the caller's home environment (empty = main Aseman).
func AccountPlatform(ctx context.Context, r *repo.Repo, id identity.ID) string {
	if r == nil || id.IsZero() {
		return tenancy.Main
	}
	var acc account.Account
	if err := r.Get(ctx, "accounts", id, &acc); err != nil {
		return tenancy.Main
	}
	return acc.PlatformID
}

// SeesEntity reports whether viewer may observe an entity on entityPlatform.
func SeesEntity(ctx context.Context, r *repo.Repo, viewer identity.ID, entityPlatform string) bool {
	bridged, _ := BridgedPlatforms(ctx, r)
	return tenancy.Sees(AccountPlatform(ctx, r, viewer), entityPlatform, bridged)
}

// FindAccountByHandle resolves a handle to an account the viewer may see.
// When several accounts share a handle across platforms, the viewer's own
// platform wins, then any other visible match.
func FindAccountByHandle(ctx context.Context, r *repo.Repo, viewer identity.ID, handle string) (*account.Account, error) {
	handle = strings.TrimSpace(strings.TrimPrefix(handle, "@"))
	if handle == "" || r == nil {
		return nil, errs.NotFound("account")
	}
	var list []account.Account
	if err := r.List(ctx, "accounts", database.Filter{Equal: map[string]any{"handle": handle}}, &list); err != nil {
		return nil, err
	}
	home := AccountPlatform(ctx, r, viewer)
	var same, visible *account.Account
	for i := range list {
		acc := &list[i]
		if !SeesEntity(ctx, r, viewer, acc.PlatformID) {
			continue
		}
		if acc.PlatformID == home {
			same = acc
			break
		}
		if visible == nil {
			visible = acc
		}
	}
	if same != nil {
		return same, nil
	}
	if visible != nil {
		return visible, nil
	}
	return nil, errs.NotFound("account " + handle)
}

// FindAccountByEmail resolves an email on a specific platform (empty = main).
// Used by enterprise SCIM and similar directory paths that live on main Aseman.
func FindAccountByEmail(ctx context.Context, r *repo.Repo, email, platformID string) (*account.Account, error) {
	email = strings.TrimSpace(email)
	if email == "" || r == nil {
		return nil, errs.NotFound("account")
	}
	equal := map[string]any{"email": email}
	if platformID != "" {
		equal["platform_id"] = platformID
	}
	var list []account.Account
	if err := r.List(ctx, "accounts", database.Filter{Equal: equal}, &list); err != nil {
		return nil, err
	}
	for i := range list {
		if list[i].PlatformID == platformID {
			return &list[i], nil
		}
	}
	// Legacy rows may omit platform_id; treat missing as main when asking for main.
	if platformID == tenancy.Main {
		for i := range list {
			if list[i].PlatformID == "" {
				return &list[i], nil
			}
		}
	}
	return nil, errs.NotFound("account")
}

// HandleTaken reports whether handle is already used on platformID.
func HandleTaken(ctx context.Context, r *repo.Repo, handle, platformID string, except identity.ID) (bool, error) {
	var list []account.Account
	if err := r.List(ctx, "accounts", database.Filter{Equal: map[string]any{"handle": handle}}, &list); err != nil {
		return false, err
	}
	for i := range list {
		if !except.IsZero() && list[i].ID == except {
			continue
		}
		if list[i].PlatformID == platformID {
			return true, nil
		}
	}
	return false, nil
}

// ResolvePlatformID looks up a platform by id or slug. Empty input is main.
func ResolvePlatformID(ctx context.Context, r *repo.Repo, ref string) (string, error) {
	ref = strings.TrimSpace(ref)
	if ref == "" || ref == "main" || ref == "aseman" {
		return tenancy.Main, nil
	}
	if id, err := identity.Parse(ref); err == nil {
		var byID platformRow
		if err := r.Get(ctx, "dev_platforms", id, &byID); err == nil && byID.ID != "" {
			return byID.ID, nil
		}
	}
	var list []platformRow
	if err := r.List(ctx, "dev_platforms", database.Filter{Equal: map[string]any{"slug": ref}, Limit: 1}, &list); err != nil {
		return "", err
	}
	if len(list) == 0 {
		return "", errs.NotFound("platform")
	}
	return list[0].ID, nil
}
