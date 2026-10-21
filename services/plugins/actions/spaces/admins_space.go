package spaces

import (
	"context"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// The admins space is the project the node administrator picks on the admin
// console's Projects page: every platform administrator is kept a member of it,
// as a project administrator. Who it is lives in settings ("admins_space");
// the members are added when it is chosen and whenever an account becomes a
// platform administrator (users calls SyncAdminsSpace).

func adminsSpaceActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "spaces", Name: "admins_space_get", Summary: "Admin: the project every platform administrator is a member of", Handler: s.adminsSpaceGet},
		helper.Action{Namespace: "spaces", Name: "admins_space_set", Summary: "Admin: choose the project every platform administrator is added to", Handler: s.adminsSpaceSet},
	}
}

// AdminsSpace returns the chosen admins space, zero when none is chosen.
func (s *Service) AdminsSpace(ctx context.Context) (identity.ID, error) {
	var raw string
	if err := bridge.Invoke(ctx, s.K, "settings", "AdminsSpace", []any{ctx}, &raw); err != nil {
		return identity.ID{}, err
	}
	if strings.TrimSpace(raw) == "" {
		return identity.ID{}, nil
	}
	return identity.Parse(raw)
}

// SyncAdminsSpace adds every platform administrator missing from the admins
// space to it and returns how many were added. Nothing is chosen, or the
// chosen project is gone: nothing to do.
func (s *Service) SyncAdminsSpace(ctx context.Context) (int, error) {
	spaceID, err := s.AdminsSpace(ctx)
	if err != nil || spaceID.IsZero() {
		return 0, err
	}
	return s.syncAdmins(ctx, spaceID)
}

func (s *Service) syncAdmins(ctx context.Context, spaceID identity.ID) (int, error) {
	if _, err := s.GetSpace(ctx, spaceID); err != nil {
		if errs.CodeOf(err) == errs.CodeNotFound {
			return 0, nil
		}
		return 0, err
	}
	admins, err := s.platformAdmins(ctx)
	if err != nil {
		return 0, err
	}
	added := 0
	for _, id := range admins {
		ok, err := s.ensureAdminMember(ctx, spaceID, id)
		if err != nil {
			return added, err
		}
		if ok {
			added++
		}
	}
	return added, nil
}

// platformAdmins lists the active human accounts with platform administrator
// access, the same set helper.RequireNodeAdmin accepts.
func (s *Service) platformAdmins(ctx context.Context) ([]identity.ID, error) {
	var rows []account.Account
	if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"kind": string(account.KindUser)}}, &rows); err != nil {
		return nil, err
	}
	handle := s.K.Env()["admin_handle"]
	out := []identity.ID{}
	for _, a := range rows {
		if a.Status == account.StatusActive && (a.Role == "admin" || (handle != "" && a.Handle == handle)) {
			out = append(out, a.ID)
		}
	}
	return out, nil
}

// ensureAdminMember makes the account a project administrator of the space,
// raising a lower role it already has; an owner stays owner. It reports
// whether anything changed.
func (s *Service) ensureAdminMember(ctx context.Context, spaceID, member identity.ID) (bool, error) {
	now := time.Now().UTC()
	if m, err := s.SpaceMembership(ctx, spaceID, member); err == nil {
		if m.CanManage() {
			return false, nil
		}
		m.Role = membership.RoleAdmin
		m.UpdatedAt = now
		return true, s.R.Update(ctx, "memberships", m.ID, m)
	} else if errs.CodeOf(err) != errs.CodeNotFound {
		return false, err
	}
	memID, err := identity.New(s.K.NodeID())
	if err != nil {
		return false, err
	}
	mem := &membership.Membership{
		Entity:  entity.Entity{ID: memID, CreatedAt: now, UpdatedAt: now},
		SpaceID: spaceID, MemberID: member, Role: membership.RoleAdmin, JoinedAt: now,
	}
	return true, s.R.CreateID(ctx, "memberships", memID, mem)
}

func (s *Service) adminsSpaceView(ctx context.Context, added int) (*api.ActionResponse, error) {
	id, err := s.AdminsSpace(ctx)
	if err != nil {
		return nil, err
	}
	out := map[string]any{"space": nil, "added": added}
	if !id.IsZero() {
		if sp, err := s.GetSpace(ctx, id); err == nil {
			out["space"] = map[string]any{"id": sp.ID.String(), "name": sp.Name}
		} else if errs.CodeOf(err) == errs.CodeNotFound {
			// The chosen project was deleted since.
			out["missing"] = id.String()
		} else {
			return nil, err
		}
	}
	return helper.JSON(out)
}

func (s *Service) adminsSpaceGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	return s.adminsSpaceView(ctx, 0)
}

func (s *Service) adminsSpaceSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"` // empty clears the choice
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	value := ""
	if strings.TrimSpace(in.Space) != "" {
		id, err := identity.Parse(in.Space)
		if err != nil {
			return nil, errs.InvalidArgument("invalid space id")
		}
		sp, err := s.GetSpace(ctx, id)
		if err != nil {
			return nil, err
		}
		if sp.DirectKey != "" {
			return nil, errs.InvalidArgument("a direct conversation cannot be the admins space")
		}
		value = id.String()
	}
	if err := bridge.Invoke(ctx, s.K, "settings", "SetAdminsSpace", []any{ctx, value}); err != nil {
		return nil, err
	}
	added, err := s.SyncAdminsSpace(ctx)
	if err != nil {
		return nil, err
	}
	return s.adminsSpaceView(ctx, added)
}
