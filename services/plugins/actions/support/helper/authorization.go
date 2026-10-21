// Shared authorization primitives used by namespace-specific services.
package helper

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

type principalKey struct{}
type internalAccessKey struct{}

// WithInternalAccess explicitly authorizes trusted maintenance without a user identity.
func WithInternalAccess(ctx context.Context) context.Context {
	return context.WithValue(ctx, internalAccessKey{}, true)
}

func InternalAccess(ctx context.Context) bool {
	v, _ := ctx.Value(internalAccessKey{}).(bool)
	return v
}

func WithActor(ctx context.Context, id identity.ID) context.Context {
	return context.WithValue(ctx, principalKey{}, id)
}

func Actor(ctx context.Context) identity.ID {
	id, _ := ctx.Value(principalKey{}).(identity.ID)
	return id
}

func CheckSpaceAccess(ctx context.Context, r *repo.Repo, actor, spaceID, roomID identity.ID, write bool, permissions ...string) error {
	if actor.IsZero() {
		return errs.Unauthenticated("authentication required")
	}
	if !roomID.IsZero() {
		room := space.Room{}
		if err := r.Get(ctx, "rooms", roomID, &room); err != nil {
			return err
		}
		if room.SpaceID != spaceID {
			return errs.Permission("room belongs to another space")
		}
	}
	var memberships []membership.Membership
	if err := r.List(ctx, "memberships", database.Filter{Equal: map[string]any{"space_id": spaceID.String(), "member_id": actor.String()}}, &memberships); err != nil {
		return err
	}
	for _, m := range memberships {
		if !m.RoomID.IsZero() && m.RoomID != roomID {
			continue
		}
		if !write || m.Role == membership.RoleOwner || m.Role == membership.RoleAdmin || m.Role == membership.RoleMember || m.Role == membership.RoleBot {
			return nil
		}
		for _, permission := range permissions {
			if m.HasPermission(permission) {
				return nil
			}
		}
	}
	return errs.Permission("space membership with appropriate permissions required")
}

// CheckContextAccess checks actors propagated by API handlers, agent dispatch and schedulers.
// Context-free calls are reserved for trusted internal maintenance.
func CheckContextAccess(ctx context.Context, r *repo.Repo, spaceID, roomID identity.ID, write bool, permissions ...string) error {
	if InternalAccess(ctx) {
		return nil
	}
	if id := Actor(ctx); !id.IsZero() {
		return CheckSpaceAccess(ctx, r, id, spaceID, roomID, write, permissions...)
	}
	return errs.Unauthenticated("execution actor required")
}

func CheckResourceManager(ctx context.Context, r *repo.Repo, spaceID, roomID, creator identity.ID, permissions ...string) error {
	actor := Actor(ctx)
	if err := CheckContextAccess(ctx, r, spaceID, roomID, true, permissions...); err != nil {
		return err
	}
	if actor.IsZero() || actor == creator {
		return nil
	}
	var rows []membership.Membership
	if err := r.List(ctx, "memberships", database.Filter{Equal: map[string]any{"space_id": spaceID.String(), "member_id": actor.String()}}, &rows); err != nil {
		return err
	}
	for _, m := range rows {
		if m.RoomID.IsZero() && m.CanManage() {
			return nil
		}
	}
	return errs.Permission("resource creator or space administrator required")
}

// RequireNodeAdmin checks the persisted foundation identity rather than trusting
// request metadata supplied by a caller or another module.
func RequireNodeAdmin(ctx context.Context, r *repo.Repo, req *api.ActionRequest, handle string) error {
	if err := RequireUser(req); err != nil {
		return err
	}
	var owner account.Account
	if handle == "" {
		return errs.Permission("administrator account required")
	}
	if err := r.Get(ctx, "accounts", req.Caller.ID, &owner); err != nil {
		return errs.Permission("administrator account required")
	}
	if owner.Kind != account.KindUser || (owner.Handle != handle && owner.Role != "admin") || owner.Status != account.StatusActive {
		return errs.Permission("not an admin")
	}
	return nil
}
