package spaces

import (
	"context"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/jsonpatch"
	"github.com/aseman/aseman/plugins/actions/spaces/models/invitation"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/permission"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/metasvc"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"strings"
	"time"
)

func (s *Service) canAssignRole(ctx context.Context, spaceID, actor, target identity.ID, next membership.Role) error {
	a, err := s.SpaceMembership(ctx, spaceID, actor)
	if err != nil || !a.CanManage() {
		return errs.Permission("space administrator required")
	}
	if next == membership.RoleOwner && !a.IsOwner() {
		return errs.Permission("only an owner can assign ownership")
	}
	if !target.IsZero() {
		t, err := s.SpaceMembership(ctx, spaceID, target)
		if err != nil {
			return err
		}
		if a.Role == membership.RoleAdmin && (t.Role == membership.RoleAdmin || t.IsOwner() || next == membership.RoleAdmin) {
			return errs.Permission("an administrator cannot change another administrator")
		}
	}
	return nil
}

func clientActions(s *Service) []api.Action {
	return append([]api.Action{
		helper.Action{Namespace: "spaces", Name: "room_update", Summary: "Rename a room or change its topic", Handler: s.roomUpdate},
		helper.Action{Namespace: "spaces", Name: "invitations_space", Summary: "List a space's invitations", Handler: s.spaceInvitations},
		helper.Action{Namespace: "spaces", Name: "invitation_revoke", Summary: "Revoke a pending invitation", Handler: s.revokeInvitation},
		helper.Action{Namespace: "spaces", Name: "pins_get", Summary: "Read ordered workspace pins", Handler: s.pinsGet},
		helper.Action{Namespace: "spaces", Name: "pins_set", Summary: "Replace ordered workspace pins", Handler: s.pinsSet},
		helper.Action{Namespace: "spaces", Name: "space_detail", Summary: "Read a workspace and its rooms and metadata", Handler: s.spaceDetail},
		helper.Action{Namespace: "spaces", Name: "space_list_all", Summary: "Administrate workspaces", Handler: s.spaceListAll},
		helper.Action{Namespace: "spaces", Name: "admin_files", Summary: "Admin: every file stored in a project", Handler: s.adminFiles},
		helper.Action{Namespace: "spaces", Name: "admin_work_log", Summary: "Admin: a project's recent runs with their events", Handler: s.adminWorkLog},
		helper.Action{Namespace: "spaces", Name: "admin_terminate_sandbox", Summary: "Admin: end a running machine that no project uses", Handler: s.adminTerminateSandbox},
		helper.Action{Namespace: "spaces", Name: "admin_sandboxes", Summary: "Admin: the machines the sandbox provider is running now", Handler: s.adminSandboxes},
		helper.Action{Namespace: "spaces", Name: "admin_storage", Summary: "Admin: the volumes the sandbox provider stores", Handler: s.adminStorage},
	}, append(append(append(append(append(append(turnActions(s), computerActions(s)...), updatesActions(s)...), seenActions(s)...), adminsSpaceActions(s)...), dbActions(s)...), openCodeActions(s)...)...)
}
func (s *Service) roomUpdate(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Room  string  `json:"room"`
		Name  *string `json:"name"`
		Topic *string `json:"topic"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Room)
	if err != nil {
		return nil, err
	}
	r, err := s.GetRoom(ctx, id)
	if err != nil {
		return nil, err
	}
	if err = s.Can(ctx, r.SpaceID, id, req.Caller.ID, permission.RoomManage); err != nil {
		return nil, err
	}
	if in.Name != nil {
		r.Name = strings.TrimSpace(*in.Name)
		if r.Name == "" {
			return nil, errs.InvalidArgument("room name required")
		}
	}
	if in.Topic != nil {
		r.Topic = *in.Topic
	}
	r.UpdatedAt = time.Now().UTC()
	if err = s.R.Update(ctx, "rooms", id, r); err != nil {
		return nil, err
	}
	return helper.JSON(r)
}
func (s *Service) spaceInvitations(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space string `json:"space"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Space)
	if err != nil {
		return nil, err
	}
	if err = s.Can(ctx, id, identity.ID{}, req.Caller.ID, permission.SpaceInvite); err != nil {
		return nil, err
	}
	var rows []invitation.Invitation
	err = s.R.List(ctx, "invitations", database.Filter{Equal: map[string]any{"space_id": id.String(), "status": string(invitation.StatusPending)}}, &rows)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"invitations": s.invitationViews(ctx, rows)})
}
func (s *Service) revokeInvitation(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Invitation string `json:"invitation"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Invitation)
	if err != nil {
		return nil, err
	}
	var inv invitation.Invitation
	if err = s.R.Get(ctx, "invitations", id, &inv); err != nil {
		return nil, err
	}
	if err = s.Can(ctx, inv.SpaceID, identity.ID{}, req.Caller.ID, permission.SpaceInvite); err != nil {
		return nil, err
	}
	if inv.Status != invitation.StatusPending {
		return nil, errs.Conflict("invitation is no longer pending")
	}
	old := inv.UpdatedAt
	inv.Status = invitation.StatusRevoked
	inv.UpdatedAt = time.Now().UTC()
	changed, err := s.R.CompareAndSwap(ctx, "invitations", id.String(), map[string]any{"status": string(invitation.StatusPending), "updated_at": old}, &inv)
	if err != nil {
		return nil, err
	}
	if !changed {
		return nil, errs.Conflict("invitation changed")
	}
	return helper.JSON(map[string]any{"ok": true})
}
func (s *Service) pinsGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	m := metasvc.Service{K: s.K, R: s.R}
	rec, err := m.Get(ctx, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	ids := []string{}
	if raw, ok := rec.Tree["workspace_pins"].([]any); ok {
		for _, v := range raw {
			if ref, ok := v.(string); ok {
				if id, e := identity.Parse(ref); e == nil {
					if _, e = s.SpaceMembership(ctx, id, req.Caller.ID); e == nil {
						ids = append(ids, ref)
					}
				}
			}
		}
	}
	return helper.JSON(map[string]any{"ids": ids})
}
func (s *Service) pinsSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		IDs []string `json:"ids"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if len(in.IDs) > 100 {
		return nil, errs.InvalidArgument("too many workspace pins")
	}
	seen := map[string]bool{}
	ids := []string{}
	for _, ref := range in.IDs {
		id, e := identity.Parse(ref)
		if e != nil {
			return nil, e
		}
		if _, e = s.SpaceMembership(ctx, id, req.Caller.ID); e != nil {
			return nil, e
		}
		if !seen[ref] {
			ids = append(ids, ref)
			seen[ref] = true
		}
	}
	m := metasvc.Service{K: s.K, R: s.R}
	if err := m.Patch(ctx, req.Caller.ID, jsonpatch.Patch{{Op: "set", Path: "workspace_pins", Value: ids}}); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ids": ids})
}
func (s *Service) spaceDetail(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space string `json:"space"`
		Admin bool   `json:"admin"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Space)
	if err != nil {
		return nil, err
	}
	if in.Admin {
		err = helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"])
	} else {
		err = s.Can(ctx, id, identity.ID{}, req.Caller.ID, permission.SpaceView)
	}
	if err != nil {
		return nil, err
	}
	sp, err := s.GetSpace(ctx, id)
	if err != nil {
		return nil, err
	}
	var rooms []space.Room
	if err = s.R.List(ctx, "rooms", database.Filter{Equal: map[string]any{"space_id": id.String()}, OrderBy: "created_at", Asc: true}, &rooms); err != nil {
		return nil, err
	}
	rooms = visibleRooms(rooms)
	meta, err := s.M.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	role := ""
	if mem, e := s.SpaceMembership(ctx, id, req.Caller.ID); e == nil {
		role = string(mem.Role)
	}
	tree := map[string]any{}
	for key, v := range meta.Tree {
		tree[key] = v
	}
	budget := map[string]any{"cap": 0, "spent": 0}
	var stored map[string]any
	if e := bridge.Invoke(ctx, s.K, "finance", "Budget", []any{ctx, id.String()}, &stored); e == nil {
		budget = stored
	}
	view := map[string]any{"space": sp, "metadata": tree, "rooms": rooms, "role": role, "budget": budget}
	if in.Admin {
		members, workers := s.adminPeople(ctx, id)
		view["owner"] = s.adminOwner(ctx, sp.OwnerID)
		view["machine"] = s.adminMachine(ctx, id)
		view["members"] = members
		view["workers"] = workers
	}
	return helper.JSON(view)
}
func (s *Service) spaceListAll(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	var rows []space.Space
	if err := s.R.List(ctx, "spaces", database.Filter{OrderBy: "created_at", Asc: false}, &rows); err != nil {
		return nil, err
	}
	// Each space carries its live activity (working = a turn is queued or running),
	// which the admin lists show as Awake/Idle.
	people := s.participants()
	type row struct {
		space.Space
		Activity map[string]any `json:"activity"`
		Owner    map[string]any `json:"owner"`
		Agents   int            `json:"agents"`
		Machine  map[string]any `json:"machine"`
	}
	out := make([]row, 0, len(rows))
	for _, sp := range rows {
		extra := s.adminListExtras(ctx, sp)
		agents, _ := extra["agents"].(int)
		out = append(out, row{Space: sp, Activity: s.spaceActivity(ctx, sp.ID, people), Owner: extra["owner"].(map[string]any), Agents: agents, Machine: extra["machine"].(map[string]any)})
	}
	return helper.JSON(map[string]any{"spaces": out})
}
