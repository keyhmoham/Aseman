package spaces

import (
	"context"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/jsonpatch"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	"github.com/aseman/aseman/plugins/actions/spaces/models/invitation"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/permission"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/mediahost"
	"github.com/aseman/aseman/plugins/actions/support/models/kv"
	"github.com/aseman/aseman/plugins/actions/support/models/metadata"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// BuildActions assembles all spaces namespace actions.
func BuildActions(s *Service) []api.Action {
	return append(append([]api.Action{
		&spaceCreateAction{s: s}, &spaceGetAction{s: s}, &spaceUpdateAction{s: s},
		&spaceDeleteAction{s: s}, &spaceListAction{s: s}, &spaceSearchAction{s: s},
		&spaceProfileAction{s: s}, &joinAction{s: s}, &leaveAction{s: s},
		&spaceMetaViewAction{s: s}, &spaceMetaPatchAction{s: s}, &spaceMetaPublicAction{s: s},
		&roomCreateAction{s: s}, &roomListAction{s: s}, &roomGetAction{s: s}, &roomDeleteAction{s: s},
		&roomProfileAction{s: s},
		&inviteAction{s: s}, &invitationsListAction{s: s}, &invitationAcceptAction{s: s}, &invitationDeclineAction{s: s},
		&membersListAction{s: s}, &memberRemoveAction{s: s}, &memberRoleAction{s: s}, &memberPermissionsAction{s: s},
		&botAddAction{s: s}, &botRemoveAction{s: s}, &botsListAction{s: s},
		&spaceAskAction{s: s},
		&widgetListAction{s: s}, &widgetActionAction{s: s},
		&deskGetAction{s: s}, &deskUpdateAction{s: s},
		&sandboxExecAction{s: s}, &sandboxStatusAction{s: s},
		&sandboxStartAction{s: s}, &sandboxStopAction{s: s},
		&toolsListAction{s: s},
		&asemanEnsureAction{s: s},
		&msgSendAction{s: s}, &msgListAction{s: s}, &msgDeleteAction{s: s},
		&msgSearchAction{s: s},
		&proxyCreateAction{s: s}, &proxyListAction{s: s}, &proxyGetAction{s: s}, &proxyOpenAction{s: s}, &proxyDeleteAction{s: s},
		&fileUploadAction{s: s}, &fileDownloadAction{s: s}, &fileGetAction{s: s},
		&fileDeleteAction{s: s}, &fileListAction{s: s},
		&kvSetAction{s: s}, &kvGetAction{s: s}, &kvListAction{s: s}, &kvDeleteAction{s: s},
	}, append(append(clientActions(s), directActions(s)...), chatActions(s)...)...), agentActions(s)...)
}

// --- spaces ---

type spaceCreateAction struct{ s *Service }

func (a *spaceCreateAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "space_create", Summary: "Create a space"}
}
func (a *spaceCreateAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Name        string        `json:"name"`
		Description string        `json:"description"`
		Metadata    metadata.Tree `json:"metadata,omitempty"`
		Bots        []string      `json:"bots,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	sp, err := a.s.CreateSpace(ctx, req.Caller.ID, in.Name, in.Description)
	if err != nil {
		return nil, err
	}
	if in.Metadata != nil {
		// Keep the name/description mirror CreateSpace seeded the tree with.
		if _, ok := in.Metadata["name"]; !ok {
			in.Metadata["name"] = sp.Name
		}
		if _, ok := in.Metadata["description"]; !ok {
			in.Metadata["description"] = sp.Description
		}
		if err := a.s.M.ReplaceTree(ctx, sp.ID, in.Metadata); err != nil {
			return nil, err
		}
	}
	added := []string{}
	for _, ref := range in.Bots {
		id, err := identity.Parse(ref)
		if err != nil {
			return nil, err
		}
		if err := a.s.AddBot(ctx, req.Caller.ID, sp.ID, identity.ID{}, id); err != nil {
			return nil, err
		}
		added = append(added, ref)
	}
	out := map[string]any{"space_id": sp.ID.String(), "name": sp.Name, "bots": added}
	if room, err := a.s.generalRoom(ctx, sp.ID); err == nil && room != nil {
		out["room_id"] = room.ID.String()
	}
	return helper.JSON(out)
}

type spaceGetAction struct{ s *Service }

func (a *spaceGetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "space_get", Summary: "Get a space"}
}
func (a *spaceGetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
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
	if resp, ok, err := helper.ProxyIfRemote(ctx, a.s.K, in.Space, "spaces", "space_get", req); ok {
		return resp, err
	}
	if err := a.s.Can(ctx, id, identity.ID{}, req.Caller.ID, permission.SpaceView); err != nil {
		return nil, err
	}
	sp, err := a.s.GetSpace(ctx, id)
	if err != nil {
		return nil, err
	}
	avatar := ""
	if rec, err := a.s.M.Get(ctx, sp.ID); err == nil && rec != nil {
		avatar = helper.TreeAvatar(rec.Tree)
	}
	return helper.JSON(map[string]any{"id": sp.ID.String(), "owner_id": sp.OwnerID.String(),
		"name": sp.Name, "description": sp.Description, "public": sp.Public, "avatar": avatar})
}

type spaceUpdateAction struct{ s *Service }

func (a *spaceUpdateAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "space_update", Summary: "Update space name/description"}
}
func (a *spaceUpdateAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space       string `json:"space"`
		Name        string `json:"name"`
		Description string `json:"description"`
		Public      *bool  `json:"public"`
		// A stored image's id; "" removes the workspace's avatar.
		Avatar *string `json:"avatar"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Space)
	if err != nil {
		return nil, err
	}
	if err := a.s.Can(ctx, id, identity.ID{}, req.Caller.ID, permission.SpaceEditMetadata); err != nil {
		return nil, err
	}
	sp, err := a.s.GetSpace(ctx, id)
	if err != nil {
		return nil, err
	}
	if in.Name != "" {
		sp.Name = in.Name
	}
	if in.Description != "" {
		sp.Description = in.Description
	}
	if in.Avatar != nil {
		avatar, err := helper.AvatarFile(ctx, a.s.R, req.Caller.ID, *in.Avatar)
		if err != nil {
			return nil, err
		}
		sp.AvatarID = identity.ID{}
		if avatar != "" {
			sp.AvatarID, _ = identity.Parse(avatar)
		}
		// Lists and profiles read the card's avatar from the metadata profile.
		if err := a.s.M.Patch(ctx, id, jsonpatch.Patch{{Op: "set", Path: "profile/avatar", Value: avatar}}); err != nil {
			return nil, err
		}
	}
	// Every project is private; a client asking for a public one is ignored.
	sp.Public = false
	sp.UpdatedAt = time.Now().UTC()
	if err := a.s.R.Update(ctx, "spaces", id, sp); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

type spaceDeleteAction struct{ s *Service }

func (a *spaceDeleteAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "space_delete", Summary: "Delete a space (owner only)"}
}
func (a *spaceDeleteAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
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
	sp, err := a.s.GetSpace(ctx, id)
	if err != nil {
		return nil, err
	}
	// The node's administrator can remove any project, including home ones.
	admin := helper.RequireNodeAdmin(ctx, a.s.R, req, a.s.K.Env()["admin_handle"]) == nil
	if !admin {
		if err := a.s.Can(ctx, id, identity.ID{}, req.Caller.ID, permission.SpaceView); err != nil {
			return nil, err
		}
		if mem, e := a.s.SpaceMembership(ctx, id, req.Caller.ID); e != nil || !mem.IsOwner() {
			return nil, errs.Permission("only a workspace owner can delete it")
		}
	}
	if sp.Home && !admin {
		return nil, errs.Permission("the home workspace is linked to the account and cannot be deleted")
	}
	// The Modal sandbox instance lives as long as the space: delete the space
	// and permanently terminate its sandbox together.
	_ = a.s.SandboxDestroy(ctx, id)
	a.s.revokeSpaceInvitations(ctx, id)
	a.s.deleteSpaceRoutines(ctx, id)
	a.s.deleteSpaceFiles(ctx, id)
	_ = a.s.R.Delete(ctx, "spaces", id)
	return helper.JSON(map[string]any{"ok": true})
}

type spaceListAction struct{ s *Service }

func (a *spaceListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "space_list", Summary: "List spaces I belong to"}
}
func (a *spaceListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Limit  int `json:"limit,omitempty"`
		Offset int `json:"offset,omitempty"`
		// Direct conversations are spaces too, but not projects: they are
		// listed only when asked for ("all" or "direct").
		Kind string `json:"kind,omitempty"`
	}
	_ = helper.Decode(req, &in)
	limit, offset := helper.Paging(in.Limit, in.Offset, 50, 200)
	var mems []membership.Membership
	if err := a.s.R.List(ctx, "memberships", database.Filter{
		Equal:   map[string]any{"member_id": req.Caller.ID.String(), "room_id": zeroRoom},
		OrderBy: "created_at", Asc: false,
	}, &mems); err != nil {
		return nil, err
	}
	out := []map[string]any{}
	people := a.s.participants()
	skipped := 0
	for _, m := range mems {
		if len(out) >= limit {
			break
		}
		if sp, err := a.s.GetSpace(ctx, m.SpaceID); err == nil {
			if (sp.Direct && in.Kind != "all" && in.Kind != "direct") || (!sp.Direct && in.Kind == "direct") {
				continue
			}
			if skipped < offset {
				skipped++
				continue
			}
			row := map[string]any{"id": sp.ID.String(), "name": sp.Name, "description": sp.Description,
				"owner_id": sp.OwnerID.String(), "role": m.Role, "public": sp.Public, "home": sp.Home,
				"direct": sp.Direct, "created_at": sp.CreatedAt, "updated_at": sp.UpdatedAt}
			// The card fields a list renders (avatar, brief) live in the
			// workspace's metadata profile.
			if rec, err := a.s.M.Get(ctx, sp.ID); err == nil && rec != nil {
				if profile, ok := rec.Tree["profile"].(map[string]any); ok {
					row["profile"] = profile
				}
				// How far the caller has read this project, on any device.
				if at := seenIn(rec.Tree, req.Caller.ID); !at.IsZero() {
					row["seen_at"] = at
				}
			}
			row["activity"] = a.s.spaceActivity(ctx, sp.ID, people)
			row["machine"] = a.s.adminMachine(ctx, sp.ID)["state"]
			out = append(out, row)
		}
	}
	return helper.JSON(map[string]any{"spaces": out})
}

type spaceSearchAction struct{ s *Service }

func (a *spaceSearchAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "space_search", Summary: "Search my spaces and public spaces by name or description"}
}
func (a *spaceSearchAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Query  string `json:"query,omitempty"`
		Limit  int    `json:"limit,omitempty"`
		Offset int    `json:"offset,omitempty"`
	}
	_ = helper.Decode(req, &in)
	limit, offset := helper.Paging(in.Limit, in.Offset, 20, 100)
	q := strings.ToLower(strings.TrimSpace(in.Query))
	matches := func(sp *space.Space) bool {
		return q == "" || strings.Contains(strings.ToLower(sp.Name), q) ||
			strings.Contains(strings.ToLower(sp.Description), q)
	}
	// The caller's own projects first (direct chats are not projects), then
	// the public ones they are not in.
	var mems []membership.Membership
	if err := a.s.R.List(ctx, "memberships", database.Filter{
		Equal:   map[string]any{"member_id": req.Caller.ID.String(), "room_id": zeroRoom},
		OrderBy: "created_at", Asc: false,
	}, &mems); err != nil {
		return nil, err
	}
	out := []map[string]any{}
	seen := map[string]bool{}
	row := func(sp *space.Space, role string) map[string]any {
		return map[string]any{"id": sp.ID.String(), "name": sp.Name, "description": sp.Description,
			"owner_id": sp.OwnerID.String(), "role": role, "member": role != "",
			"public": sp.Public, "home": sp.Home, "avatar": a.s.spaceAvatar(ctx, sp.ID)}
	}
	for _, m := range mems {
		sp, err := a.s.GetSpace(ctx, m.SpaceID)
		if err != nil || sp.Direct || seen[sp.ID.String()] {
			continue
		}
		seen[sp.ID.String()] = true
		if matches(sp) {
			out = append(out, row(sp, string(m.Role)))
		}
	}
	var public []space.Space
	if err := a.s.R.List(ctx, "spaces", database.Filter{
		Equal: map[string]any{"public": true}, OrderBy: "created_at", Asc: false,
	}, &public); err != nil {
		return nil, err
	}
	for i := range public {
		sp := &public[i]
		if sp.Direct || seen[sp.ID.String()] || !matches(sp) {
			continue
		}
		seen[sp.ID.String()] = true
		out = append(out, row(sp, ""))
	}
	if offset > len(out) {
		offset = len(out)
	}
	out = out[offset:]
	if len(out) > limit {
		out = out[:limit]
	}
	return helper.JSON(map[string]any{"spaces": out})
}

// --- space metadata ---

type spaceMetaViewAction struct{ s *Service }

func (a *spaceMetaViewAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "metadata_view", Summary: "View space metadata (visibility filtered)"}
}
func (a *spaceMetaViewAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
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
	if resp, ok, err := helper.ProxyIfRemote(ctx, a.s.K, in.Space, "spaces", "metadata_view", req); ok {
		return resp, err
	}
	sp, err := a.s.GetSpace(ctx, id)
	if err != nil {
		return nil, err
	}
	isMember := a.s.Can(ctx, id, identity.ID{}, req.Caller.ID, permission.SpaceView) == nil
	var rec *metadata.Record
	if isMember {
		rec, err = a.s.M.Get(ctx, sp.ID)
	} else {
		rec, err = a.s.M.View(ctx, req.Caller.ID, sp.ID)
	}
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"owner": rec.Owner, "tree": rec.Tree,
		"public_paths": rec.PublicPaths, "version": rec.Version})
}

type spaceMetaPatchAction struct{ s *Service }

func (a *spaceMetaPatchAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "metadata_patch", Summary: "Patch space metadata"}
}
func (a *spaceMetaPatchAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string          `json:"space"`
		Patch jsonpatch.Patch `json:"patch"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Space)
	if err != nil {
		return nil, err
	}
	if err := a.s.Can(ctx, id, identity.ID{}, req.Caller.ID, permission.SpaceEditMetadata); err != nil {
		return nil, err
	}
	if err := a.s.M.Patch(ctx, id, in.Patch); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

type spaceMetaPublicAction struct{ s *Service }

func (a *spaceMetaPublicAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "metadata_public", Summary: "Set space public metadata paths"}
}
func (a *spaceMetaPublicAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string   `json:"space"`
		Paths []string `json:"paths"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Space)
	if err != nil {
		return nil, err
	}
	if err := a.s.Can(ctx, id, identity.ID{}, req.Caller.ID, permission.SpaceEditMetadata); err != nil {
		return nil, err
	}
	if err := a.s.M.SetPublicPaths(ctx, id, in.Paths); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "paths": jsonpatch.Paths(in.Paths).Normalize()})
}

// --- rooms ---

type roomCreateAction struct{ s *Service }

func (a *roomCreateAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "room_create", Summary: "Create a room in a space"}
}
func (a *roomCreateAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Name  string `json:"name"`
		Topic string `json:"topic"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, err
	}
	if err := a.s.Can(ctx, spID, identity.ID{}, req.Caller.ID, permission.SpaceManageRooms); err != nil {
		return nil, err
	}
	id, err := identity.New(a.s.K.NodeID())
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	room := &space.Room{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		SpaceID: spID, Name: in.Name, Topic: in.Topic, MetadataID: id}
	if err := a.s.R.CreateID(ctx, "rooms", id, room); err != nil {
		return nil, err
	}
	meta := &metadata.Record{Owner: id.String(), Tree: metadata.Tree{"name": in.Name, "topic": in.Topic},
		PublicPaths: []string{}, Version: 1, UpdatedAt: now}
	if err := a.s.R.CreateID(ctx, "metadatas", id, meta); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"room_id": id.String()})
}

type roomListAction struct{ s *Service }

func (a *roomListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "room_list", Summary: "List rooms of a space"}
}
func (a *roomListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space  string `json:"space"`
		Limit  int    `json:"limit,omitempty"`
		Offset int    `json:"offset,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, err
	}
	if err := a.s.Can(ctx, spID, identity.ID{}, req.Caller.ID, permission.SpaceView); err != nil {
		return nil, err
	}
	limit, offset := helper.Paging(in.Limit, in.Offset, 50, 200)
	var rooms []space.Room
	if err := a.s.R.List(ctx, "rooms", database.Filter{
		Equal: map[string]any{"space_id": spID.String()}, OrderBy: "created_at", Asc: false, Limit: limit, Offset: offset,
	}, &rooms); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"rooms": rooms})
}

type roomGetAction struct{ s *Service }

func (a *roomGetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "room_get", Summary: "Get a room"}
}
func (a *roomGetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Room string `json:"room"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	rid, err := identity.Parse(in.Room)
	if err != nil {
		return nil, err
	}
	room, err := a.s.GetRoom(ctx, rid)
	if err != nil {
		return nil, err
	}
	if err := a.s.Can(ctx, room.SpaceID, rid, req.Caller.ID, permission.RoomRead); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"id": room.ID.String(), "space_id": room.SpaceID.String(),
		"name": room.Name, "topic": room.Topic})
}

type roomDeleteAction struct{ s *Service }

func (a *roomDeleteAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "room_delete", Summary: "Delete a room"}
}
func (a *roomDeleteAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Room string `json:"room"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	rid, err := identity.Parse(in.Room)
	if err != nil {
		return nil, err
	}
	room, err := a.s.GetRoom(ctx, rid)
	if err != nil {
		return nil, err
	}
	if err := a.s.Can(ctx, room.SpaceID, rid, req.Caller.ID, permission.RoomManage); err != nil {
		return nil, err
	}
	_ = a.s.R.Delete(ctx, "rooms", rid)
	return helper.JSON(map[string]any{"ok": true})
}

// --- invitations & members ---

type inviteAction struct{ s *Service }

func (a *inviteAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "invite", Summary: "Invite an account to a space"}
}
func (a *inviteAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space   string `json:"space"`
		Room    string `json:"room,omitempty"`
		Invitee string `json:"invitee"`
		Role    string `json:"role,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, err
	}
	if err := a.s.Can(ctx, spID, identity.ID{}, req.Caller.ID, permission.SpaceInvite); err != nil {
		return nil, err
	}
	invitee, err := identity.Parse(in.Invitee)
	if err != nil {
		return nil, err
	}
	roomID := identity.ID{}
	if in.Room != "" {
		roomID, err = identity.Parse(in.Room)
		if err != nil {
			return nil, err
		}
	}
	role := membership.RoleMember
	if in.Role != "" {
		role = membership.Role(in.Role)
	}
	if !membership.ValidRole(role) || role == membership.RoleBot {
		return nil, errs.InvalidArgument("invalid collaborator role")
	}
	if err := a.s.canAssignRole(ctx, spID, req.Caller.ID, identity.ID{}, role); err != nil {
		return nil, err
	}
	inv, err := a.s.Invite(ctx, req.Caller.ID, spID, roomID, invitee, role)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"invitation_id": inv.ID.String()})
}

type invitationsListAction struct{ s *Service }

func (a *invitationsListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "invitations_list", Summary: "List my pending invitations"}
}
func (a *invitationsListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Limit  int `json:"limit,omitempty"`
		Offset int `json:"offset,omitempty"`
	}
	_ = helper.Decode(req, &in)
	limit, offset := helper.Paging(in.Limit, in.Offset, 50, 200)
	inv, err := a.s.ListInvitations(ctx, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	start := offset
	if start > len(inv) {
		start = len(inv)
	}
	end := len(inv)
	if limit > 0 && start+limit < end {
		end = start + limit
	}
	return helper.JSON(map[string]any{"invitations": a.s.invitationViews(ctx, inv[start:end])})
}

type invitationAcceptAction struct{ s *Service }

func (a *invitationAcceptAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "invitation_accept", Summary: "Accept an invitation"}
}
func (a *invitationAcceptAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Invitation string `json:"invitation"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	invID, err := identity.Parse(in.Invitation)
	if err != nil {
		return nil, err
	}
	if err := a.s.AcceptInvitation(ctx, req.Caller.ID, invID); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

type invitationDeclineAction struct{ s *Service }

func (a *invitationDeclineAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "invitation_decline", Summary: "Decline an invitation"}
}
func (a *invitationDeclineAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Invitation string `json:"invitation"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	invID, err := identity.Parse(in.Invitation)
	if err != nil {
		return nil, err
	}
	inv := &invitation.Invitation{}
	if err := a.s.R.Get(ctx, "invitations", invID, inv); err != nil {
		return nil, err
	}
	if inv.InviteeID != req.Caller.ID {
		return nil, errs.Permission("not your invitation")
	}
	inv.Status = invitation.StatusDeclined
	inv.UpdatedAt = time.Now().UTC()
	_ = a.s.R.Update(ctx, "invitations", invID, inv)
	return helper.JSON(map[string]any{"ok": true})
}

type membersListAction struct{ s *Service }

func (a *membersListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "members_list", Summary: "List space members"}
}
func (a *membersListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space string `json:"space"`
		// Kind optionally keeps only members whose account is of that kind
		// ("user" for people, "bot" for agents and apps). Empty lists everyone,
		// which is what agents rely on to see their team.
		Kind   string `json:"kind,omitempty"`
		Limit  int    `json:"limit,omitempty"`
		Offset int    `json:"offset,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, err
	}
	if err := a.s.Can(ctx, spID, identity.ID{}, req.Caller.ID, permission.SpaceView); err != nil {
		return nil, err
	}
	limit, offset := helper.Paging(in.Limit, in.Offset, 50, 200)
	filter := database.Filter{
		Equal: map[string]any{"space_id": spID.String()}, OrderBy: "created_at", Asc: false, Limit: limit, Offset: offset,
	}
	if in.Kind != "" {
		// The kind lives on the account, so filter the whole list and page
		// afterwards; paging first would return short or empty pages.
		filter.Limit, filter.Offset = 0, 0
	}
	var mems []membership.Membership
	if err := a.s.R.List(ctx, "memberships", filter, &mems); err != nil {
		return nil, err
	}
	if in.Kind != "" {
		kept := mems[:0]
		for i := range mems {
			var acc account.Account
			if a.s.R.Get(ctx, "accounts", mems[i].MemberID, &acc) == nil && string(acc.Kind) == in.Kind {
				kept = append(kept, mems[i])
			}
		}
		if offset > len(kept) {
			offset = len(kept)
		}
		kept = kept[offset:]
		if len(kept) > limit {
			kept = kept[:limit]
		}
		mems = kept
	}
	return helper.JSON(map[string]any{"members": a.s.enrichMembers(ctx, mems)})
}

type memberRemoveAction struct{ s *Service }

func (a *memberRemoveAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "member_remove", Summary: "Remove a member from the space"}
}
func (a *memberRemoveAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space  string `json:"space"`
		Member string `json:"member"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	member, _ := identity.Parse(in.Member)
	if err := a.s.Can(ctx, spID, identity.ID{}, req.Caller.ID, permission.SpaceRemove); err != nil {
		return nil, err
	}
	target, err := a.s.SpaceMembership(ctx, spID, member)
	if err != nil {
		return nil, err
	}
	if target.IsOwner() {
		return nil, errs.Permission("cannot remove the owner")
	}
	if err := a.s.canAssignRole(ctx, spID, req.Caller.ID, member, membership.RoleMember); err != nil {
		return nil, err
	}
	if err := a.s.R.Delete(ctx, "memberships", target.ID); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

type memberRoleAction struct{ s *Service }

func (a *memberRoleAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "member_role", Summary: "Set a member's role"}
}
func (a *memberRoleAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space  string `json:"space"`
		Member string `json:"member"`
		Role   string `json:"role"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	member, _ := identity.Parse(in.Member)
	if err := a.s.Can(ctx, spID, identity.ID{}, req.Caller.ID, permission.SpaceManageMembers); err != nil {
		return nil, err
	}
	target, err := a.s.SpaceMembership(ctx, spID, member)
	if err != nil {
		return nil, err
	}
	if target.IsOwner() {
		return nil, errs.Permission("cannot change the owner's role")
	}
	next := membership.Role(in.Role)
	if !membership.ValidRole(next) || next == membership.RoleBot {
		return nil, errs.InvalidArgument("invalid collaborator role")
	}
	if err := a.s.canAssignRole(ctx, spID, req.Caller.ID, member, next); err != nil {
		return nil, err
	}
	target.Role = next
	target.UpdatedAt = time.Now().UTC()
	if err := a.s.R.Update(ctx, "memberships", target.ID, target); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

type memberPermissionsAction struct{ s *Service }

func (a *memberPermissionsAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "member_permissions", Summary: "Set a member's explicit permission grants"}
}
func (a *memberPermissionsAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space       string   `json:"space"`
		Member      string   `json:"member"`
		Permissions []string `json:"permissions"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	member, _ := identity.Parse(in.Member)
	if err := a.s.Can(ctx, spID, identity.ID{}, req.Caller.ID, permission.SpaceManageMembers); err != nil {
		return nil, err
	}
	target, err := a.s.SpaceMembership(ctx, spID, member)
	if err != nil {
		return nil, err
	}
	if target.IsOwner() {
		return nil, errs.Permission("cannot modify the owner's permissions")
	}
	target.Permissions = in.Permissions
	target.UpdatedAt = time.Now().UTC()
	if err := a.s.R.Update(ctx, "memberships", target.ID, target); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

// --- bots ---

type botAddAction struct{ s *Service }

func (a *botAddAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "bot_add", Summary: "Add a bot to a space/room"}
}
func (a *botAddAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Room  string `json:"room,omitempty"`
		Bot   string `json:"bot"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	roomID, _ := identity.Parse(in.Room)
	botID, _ := identity.Parse(in.Bot)
	if err := a.s.Can(ctx, spID, roomID, req.Caller.ID, permission.SpaceManageBots); err != nil {
		return nil, err
	}
	if err := a.s.AddBot(ctx, req.Caller.ID, spID, roomID, botID); err != nil {
		return nil, err
	}
	a.s.installTool(ctx, spID, botID)
	return helper.JSON(map[string]any{"ok": true})
}

type botRemoveAction struct{ s *Service }

func (a *botRemoveAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "bot_remove", Summary: "Remove a bot from a space/room"}
}
func (a *botRemoveAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Room  string `json:"room,omitempty"`
		Bot   string `json:"bot"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	roomID, _ := identity.Parse(in.Room)
	botID, _ := identity.Parse(in.Bot)
	if err := a.s.Can(ctx, spID, roomID, req.Caller.ID, permission.SpaceManageBots); err != nil {
		return nil, err
	}
	// Both of the bot's ids may be what a membership was recorded with.
	ids := map[string]bool{botID.String(): true, a.s.botAccountOf(ctx, botID).String(): true}
	for id := range ids {
		filter := database.Filter{Equal: map[string]any{
			"space_id": spID.String(), "room_id": roomID.String(), "member_id": id,
		}}
		var mems []membership.Membership
		if err := a.s.R.List(ctx, "memberships", filter, &mems); err != nil {
			return nil, err
		}
		for i := range mems {
			_ = a.s.R.Delete(ctx, "memberships", mems[i].ID)
		}
	}
	return helper.JSON(map[string]any{"ok": true})
}

type botsListAction struct{ s *Service }

func (a *botsListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "bots_list", Summary: "List the bots (agents and apps) installed in a space"}
}
func (a *botsListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	if err := a.s.Can(ctx, spID, identity.ID{}, req.Caller.ID, permission.SpaceView); err != nil {
		return nil, err
	}
	// Agents need the shared sandbox as an app (bot id for routines, ask, …).
	// People-facing clients omit it; it is a computer, not an installable app.
	forAgents := a.s.isBotAccount(ctx, req.Caller.ID)
	var mems []membership.Membership
	if err := a.s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": spID.String(), "role": string(membership.RoleBot)},
	}, &mems); err != nil {
		return nil, err
	}
	var bots []map[string]any
	seen := map[string]bool{}
	for i := range mems {
		rec, err := a.s.botForMember(ctx, mems[i].MemberID)
		if err != nil {
			continue
		}
		if !forAgents && rec.IsSandbox() {
			continue
		}
		if seen[rec.ID.String()] {
			continue
		}
		seen[rec.ID.String()] = true
		bots = append(bots, map[string]any{
			"id":          rec.ID.String(),
			"account_id":  rec.AccountID.String(),
			"name":        rec.Name,
			"kind":        string(rec.Kind),
			"vm_type":     string(rec.VMType),
			"status":      string(rec.Status),
			"vm_id":       rec.VMID,
			"member_id":   mems[i].MemberID.String(),
			"description": a.s.toolDescription(ctx, rec),
			"owner_id":    rec.OwnerID.String(),
			"avatar":      a.s.participants().get(ctx, rec.AccountID)["avatar"],
			"cost":        rec.Cost,
			"resources":   rec.Resources,
		})
	}
	return helper.JSON(map[string]any{"bots": bots})
}

// --- messages ---

type msgSendAction struct{ s *Service }

func (a *msgSendAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "message_send", Summary: "Send a message to a room"}
}
func (a *msgSendAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	if a.s.runStopped(ctx) {
		return nil, errs.New(errs.CodeUnavailable, "the work was stopped")
	}
	var in struct {
		Space       string   `json:"space"`
		Room        string   `json:"room"`
		Body        string   `json:"body"`
		Mentions    []string `json:"mentions,omitempty"`
		Attachments []string `json:"attachments,omitempty"`
		// ReplyTo marks the message as an answer to another message of the room.
		ReplyTo string `json:"reply_to,omitempty"`
		// Wait delivers the message to the agents it mentions before returning
		// and returns their replies: how an agent hands work to another agent
		// and gets its answer, with no polling. The replies are stored in the
		// room as answers to the message, as always.
		Wait bool `json:"wait,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	roomID, _ := identity.Parse(in.Room)
	if in.ReplyTo != "" {
		if _, err := identity.Parse(in.ReplyTo); err != nil {
			return nil, errs.InvalidArgument("invalid reply_to message id")
		}
	}
	if err := a.s.Can(ctx, spID, roomID, req.Caller.ID, permission.RoomSend); err != nil {
		return nil, err
	}
	if in.Body == "" && len(in.Attachments) == 0 {
		return nil, errs.InvalidArgument("body or attachments required")
	}
	// Host remote designer media on Aseman before the message is stored so
	// readers never hit the original URL.
	if in.Body != "" {
		hosted, _, err := mediahost.HostBody(ctx, a.s.K, req.Caller.ID, in.Body)
		if err != nil {
			return nil, err
		}
		if hosted != "" {
			in.Body = hosted
		}
	}
	if blocked, byMe := a.s.directBlock(ctx, spID, req.Caller.ID); blocked {
		return nil, blockError(byMe)
	}
	in.Mentions = a.s.directMentions(ctx, spID, req.Caller.ID, in.Mentions)
	// An agent handing work to agents is refused up front when the chain is
	// already as deep as it may go, so the sender hears it instead of waiting
	// on a reply that will never come.
	if len(in.Mentions) > 0 && vmm.AgentAskDepth(ctx) >= vmm.MaxAgentAskDepth && a.s.isBotAccount(ctx, req.Caller.ID) {
		return nil, errs.Conflict("the chain of agents asking agents is too deep to start another agent; finish the work yourself or report back")
	}
	// Resolve and authorize every referenced attachment before persisting so a
	// sender can only attach files they can read in the room.
	for _, ref := range in.Attachments {
		fileID, perr := identity.Parse(ref)
		if perr != nil {
			return nil, errs.InvalidArgument("invalid attachment id")
		}
		if err := a.s.CanReadFile(ctx, fileID, req.Caller.ID); err != nil {
			return nil, err
		}
	}
	id, err := identity.New(a.s.K.NodeID())
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	msg := &message.Message{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		SpaceID: spID, RoomID: roomID, SenderID: req.Caller.ID, Body: in.Body, ReplyTo: in.ReplyTo}
	msg.SetMentions(in.Mentions)
	msg.SetAttachments(in.Attachments)
	if err := a.s.R.CreateID(ctx, "messages", id, msg); err != nil {
		return nil, err
	}
	setTyping(roomID, req.Caller.ID, false) // the message is written
	a.s.notifyRoomMessage(msg)
	// Deliver the message to the space's agents: mentioned agents are
	// triggered to respond, others record it as conversation history.
	// Hard enforcement: mentioning agents costs at least one credit each, so
	// the payer (the sender, or the person an agent works for) must be able to
	// cover the mentions before they are triggered.
	payer := a.s.payer(ctx, req.Caller.ID)
	if len(in.Mentions) > 0 {
		if err := a.s.Bots.EnsureBalance(billingScope(ctx, spID, roomID, identity.ID{}, payer), payer, int64(len(in.Mentions))); err != nil {
			return nil, err
		}
	}
	if in.Wait && len(in.Mentions) > 0 {
		// The sender's turn waits on the agents it asked, so they work on its
		// run, stop with it and keep its scope (who pays, how deep the chain is).
		deliveryCtx, done := a.s.joinRun(ctx)
		defer done()
		replies, derr := a.s.DeliverMentions(deliveryCtx, spID, roomID, msg)
		out := map[string]any{"message_id": id.String(), "ok": true, "replies": replies}
		if derr != nil {
			out["error"] = derr.Error()
		}
		return helper.JSON(out)
	}
	// Asynchronous delivery: the room message returns immediately and every
	// agent's reply arrives later as its own chat message (an answer to this
	// one), so people ↔ people, people ↔ agents and agents ↔ agents all happen
	// through the message stream. A delivery started by an agent keeps its
	// run's scope (who pays, how deep the chain is) but not its deadline.
	deliveryCtx := context.WithoutCancel(ctx)
	if payer == req.Caller.ID {
		deliveryCtx = context.Background()
	}
	a.s.deliverMentionsAsync(deliveryCtx, spID, roomID, msg, req.Caller.ID)
	out := map[string]any{"message_id": id.String(), "ok": true}
	return helper.JSON(out)
}

type msgListAction struct{ s *Service }

func (a *msgListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "message_list", Summary: "List messages in a room"}
}
func (a *msgListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	// Before pages back through history; After reads what arrived since a
	// message the client already holds. Both are message creation times and the
	// response is always newest first.
	var in struct {
		Space  string    `json:"space"`
		Room   string    `json:"room"`
		Limit  int       `json:"limit"`
		Before time.Time `json:"before,omitempty"`
		After  time.Time `json:"after,omitempty"`
		// ReplyTo reads only the answers to one message (e.g. the reply an
		// agent posted to a task it was given).
		ReplyTo string `json:"reply_to,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	roomID, _ := identity.Parse(in.Room)
	if err := a.s.Can(ctx, spID, roomID, req.Caller.ID, permission.RoomRead); err != nil {
		return nil, err
	}
	if in.Limit <= 0 || in.Limit > 200 {
		in.Limit = 50
	}
	filter := database.Filter{
		Equal:   map[string]any{"space_id": spID.String(), "room_id": roomID.String()},
		OrderBy: "created_at", Asc: false, Limit: in.Limit + 1,
	}
	if in.ReplyTo != "" {
		filter.Equal["reply_to"] = in.ReplyTo
	}
	if !in.Before.IsZero() {
		filter.LessThan = map[string]any{"created_at": in.Before.UTC()}
	}
	if !in.After.IsZero() {
		filter.GreaterThan = map[string]any{"created_at": in.After.UTC()}
		filter.Asc = true
	}
	// A direct chat the caller deleted for themselves starts again after.
	sp, _ := a.s.GetSpace(ctx, spID)
	direct := sp != nil && sp.Direct
	tree := map[string]any{}
	if direct {
		tree = a.s.chatTree(ctx, spID)
		if cleared := clearedIn(tree, req.Caller.ID); !cleared.IsZero() && cleared.After(in.After) {
			filter.GreaterThan = map[string]any{"created_at": cleared.UTC()}
		}
	}
	var msgs []message.Message
	if err := a.s.R.List(ctx, "messages", filter, &msgs); err != nil {
		return nil, err
	}
	hasMore := len(msgs) > in.Limit
	if hasMore {
		msgs = msgs[:in.Limit]
	}
	if filter.Asc {
		for i, j := 0, len(msgs)-1; i < j; i, j = i+1, j-1 {
			msgs[i], msgs[j] = msgs[j], msgs[i]
		}
	}
	msgs = withoutToolMessages(msgs)
	// Surface which agent is currently working in this room (if any) and what it
	// is doing right now, so the client can show a live status sentence under the
	// chat ("code-agent is running in the sandbox", "aseman is planning", …).
	working, workingDetail := "", ""
	if agent, detail, ok := a.s.RoomActivity(roomID); ok {
		working, workingDetail = agent, detail
	}
	out := map[string]any{
		"messages":       a.s.enrichMessages(ctx, msgs),
		"has_more":       hasMore,
		"working":        working,
		"working_detail": workingDetail,
	}
	people := a.s.participants()
	typingNow := []map[string]any{}
	for _, id := range typingIn(roomID, req.Caller.ID) {
		typingNow = append(typingNow, people.get(ctx, id))
	}
	out["typing"] = typingNow
	if direct {
		// How far the other side has read (the client marks the caller's
		// messages up to it as seen), and whether anyone can write.
		peers := a.s.directPeers(ctx, spID, req.Caller.ID)
		out["saved"] = len(peers) == 0
		mine := blockedIn(tree, req.Caller.ID)
		theirs := false
		for _, p := range peers {
			theirs = theirs || blockedIn(tree, p)
			if seen := a.s.SeenAt(ctx, p, spID); !seen.IsZero() {
				out["peer_seen_at"] = seen
			}
		}
		out["blocked"] = mine
		out["can_send"] = !mine && !theirs
	}
	return helper.JSON(out)
}

type msgDeleteAction struct{ s *Service }

func (a *msgDeleteAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "message_delete", Summary: "Delete a message"}
}
func (a *msgDeleteAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Msg   string `json:"message"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	msgID, _ := identity.Parse(in.Msg)
	msg := &message.Message{}
	if err := a.s.R.Get(ctx, "messages", msgID, msg); err != nil {
		return nil, err
	}
	if msg.SpaceID != spID {
		return nil, errs.NotFound("message not found")
	}
	// The sender takes back their own message (for everyone); a manager of
	// a project can delete anyone's. A direct chat has no manager: whoever
	// opened it does not moderate the other side.
	sp, err := a.s.GetSpace(ctx, spID)
	if err != nil {
		return nil, err
	}
	if msg.SenderID == req.Caller.ID {
		if err := a.s.Can(ctx, spID, msg.RoomID, req.Caller.ID, permission.RoomSend); err != nil {
			return nil, err
		}
	} else if sp.Direct || a.s.Can(ctx, spID, msg.RoomID, req.Caller.ID, permission.SpaceManageMessages) != nil {
		return nil, errs.Permission("only the sender or a manager can delete")
	}
	a.s.deleteMessageEdits(ctx, msgID)
	_ = a.s.R.Delete(ctx, "messages", msgID)
	return helper.JSON(map[string]any{"ok": true})
}

// msgSearchAction implements spaces.message_search: search room messages across
// the whole space, newest first (Explore → in-space messages tab).
type msgSearchAction struct{ s *Service }

func (a *msgSearchAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "message_search", Summary: "Search messages across a space"}
}
func (a *msgSearchAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space  string `json:"space"`
		Query  string `json:"query,omitempty"`
		Limit  int    `json:"limit,omitempty"`
		Offset int    `json:"offset,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	if err := a.s.Can(ctx, spID, identity.ID{}, req.Caller.ID, permission.SpaceView); err != nil {
		return nil, err
	}
	msgs, err := a.s.MessageSearch(ctx, spID, in.Query, in.Limit, in.Offset)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"messages": a.s.enrichMessages(ctx, msgs)})
}

// --- files ---

type fileUploadAction struct{ s *Service }

func (a *fileUploadAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "file_upload", Summary: "Upload a file to a space/room"}
}
func (a *fileUploadAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Room  string `json:"room,omitempty"`
		Name  string `json:"name"`
		Mime  string `json:"mime"`
		Data  []byte `json:"data"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	roomID, _ := identity.Parse(in.Room)
	if err := a.s.Can(ctx, spID, roomID, req.Caller.ID, permission.RoomUpload); err != nil {
		return nil, err
	}
	file, err := a.s.UploadFile(ctx, req.Caller.ID, spID, roomID, in.Name, in.Mime, in.Data)
	if err != nil {
		return nil, err
	}
	return helper.JSON(a.s.fileMeta(ctx, file))
}

// fileGetAction returns a single file's metadata, optionally including the
// binary payload (base64 in `data`). This is the canonical "preview" entry
// point: the client can render thumbnails/players straight from the
// `content_url` without downloading the whole payload.
type fileGetAction struct{ s *Service }

func (a *fileGetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "file_get", Summary: "Get a space file's metadata (optionally with payload)"}
}
func (a *fileGetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		File     string `json:"file"`
		WithData bool   `json:"with_data,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	fileID, _ := identity.Parse(in.File)
	file, err := a.s.GetFile(ctx, fileID)
	if err != nil {
		return nil, err
	}
	if err := a.s.CanReadFile(ctx, file.ID, req.Caller.ID); err != nil {
		return nil, err
	}
	out := a.s.fileMeta(ctx, file)
	if in.WithData {
		if data, err := a.s.ReadFileBytes(ctx, file); err == nil {
			out["data"] = data
		}
	}
	return helper.JSON(out)
}

type fileDownloadAction struct{ s *Service }

func (a *fileDownloadAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "file_download", Summary: "Download a space file"}
}
func (a *fileDownloadAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		File string `json:"file"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	fileID, _ := identity.Parse(in.File)
	file, err := a.s.GetFile(ctx, fileID)
	if err != nil {
		return nil, err
	}
	if err := a.s.CanReadFile(ctx, file.ID, req.Caller.ID); err != nil {
		return nil, err
	}
	data, err := a.s.ReadFileBytes(ctx, file)
	if err != nil {
		return nil, err
	}
	out := a.s.fileMeta(ctx, file)
	out["data"] = data
	return helper.JSON(out)
}

type fileDeleteAction struct{ s *Service }

func (a *fileDeleteAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "file_delete", Summary: "Delete a space file"}
}
func (a *fileDeleteAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		File string `json:"file"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	fileID, _ := identity.Parse(in.File)
	file, err := a.s.GetFile(ctx, fileID)
	if err != nil {
		return nil, err
	}
	if err := a.s.Can(ctx, file.SpaceID, file.RoomID, req.Caller.ID, permission.RoomDeleteFiles); err != nil {
		return nil, err
	}
	if fs := a.s.K.FS(); fs != nil {
		_ = fs.Delete(ctx, file.StorageKey)
	}
	_ = a.s.R.Delete(ctx, "files", fileID)
	return helper.JSON(map[string]any{"ok": true})
}

type fileListAction struct{ s *Service }

func (a *fileListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "file_list", Summary: "List files in a space/room"}
}
func (a *fileListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space  string `json:"space"`
		Room   string `json:"room,omitempty"`
		Limit  int    `json:"limit,omitempty"`
		Offset int    `json:"offset,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	roomID, _ := identity.Parse(in.Room)
	if err := a.s.Can(ctx, spID, roomID, req.Caller.ID, permission.RoomRead); err != nil {
		return nil, err
	}
	limit, offset := helper.Paging(in.Limit, in.Offset, 50, 200)
	var files []filedata.File
	if err := a.s.R.List(ctx, "files", database.Filter{
		Equal:   map[string]any{"space_id": spID.String(), "room_id": roomID.String()},
		OrderBy: "created_at", Asc: false, Limit: limit, Offset: offset,
	}, &files); err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(files))
	for i := range files {
		out = append(out, a.s.fileMeta(ctx, &files[i]))
	}
	return helper.JSON(map[string]any{"files": out})
}

// --- kv ---

type kvSetAction struct{ s *Service }

func (a *kvSetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "kv_set", Summary: "Set a bot KV value in a space/room"}
}
func (a *kvSetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Room  string `json:"room,omitempty"`
		Key   string `json:"key"`
		Value string `json:"value"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	roomID, _ := identity.Parse(in.Room)
	scope, scopeID := kv.ScopeSpace, spID
	if !roomID.IsZero() {
		scope, scopeID = kv.ScopeRoom, roomID
	}
	if err := a.s.Can(ctx, spID, roomID, req.Caller.ID, permission.RoomKV); err != nil {
		return nil, err
	}
	if err := a.s.KV.Set(ctx, scope, scopeID, req.Caller.ID, in.Key, in.Value); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

type kvGetAction struct{ s *Service }

func (a *kvGetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "kv_get", Summary: "Get a bot KV value"}
}
func (a *kvGetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Room  string `json:"room,omitempty"`
		Key   string `json:"key"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	roomID, _ := identity.Parse(in.Room)
	scope, scopeID := kv.ScopeSpace, spID
	if !roomID.IsZero() {
		scope, scopeID = kv.ScopeRoom, roomID
	}
	if err := a.s.Can(ctx, spID, roomID, req.Caller.ID, permission.RoomKV); err != nil {
		return nil, err
	}
	item, err := a.s.KV.Get(ctx, scope, scopeID, req.Caller.ID, in.Key)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"key": item.Key, "value": item.Value})
}

type kvListAction struct{ s *Service }

func (a *kvListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "kv_list", Summary: "List my KV entries in a space/room"}
}
func (a *kvListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space  string `json:"space"`
		Room   string `json:"room,omitempty"`
		Limit  int    `json:"limit,omitempty"`
		Offset int    `json:"offset,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	roomID, _ := identity.Parse(in.Room)
	scope, scopeID := kv.ScopeSpace, spID
	if !roomID.IsZero() {
		scope, scopeID = kv.ScopeRoom, roomID
	}
	if err := a.s.Can(ctx, spID, roomID, req.Caller.ID, permission.RoomKV); err != nil {
		return nil, err
	}
	limit, offset := helper.Paging(in.Limit, in.Offset, 50, 200)
	items, err := a.s.KV.Range(ctx, scope, scopeID, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	start := offset
	if start > len(items) {
		start = len(items)
	}
	end := len(items)
	if limit > 0 && start+limit < end {
		end = start + limit
	}
	return helper.JSON(map[string]any{"items": items[start:end]})
}

type kvDeleteAction struct{ s *Service }

func (a *kvDeleteAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "kv_delete", Summary: "Delete a bot KV value"}
}
func (a *kvDeleteAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
		Room  string `json:"room,omitempty"`
		Key   string `json:"key"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	roomID, _ := identity.Parse(in.Room)
	scope, scopeID := kv.ScopeSpace, spID
	if !roomID.IsZero() {
		scope, scopeID = kv.ScopeRoom, roomID
	}
	if err := a.s.Can(ctx, spID, roomID, req.Caller.ID, permission.RoomKV); err != nil {
		return nil, err
	}
	if err := a.s.KV.Delete(ctx, scope, scopeID, req.Caller.ID, in.Key); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

// --- small helpers used by this package ---

func containsFold(a, b string) bool {
	return len(a) >= len(b) && indexFold(a, b) >= 0
}

func indexFold(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if equalFold(s[i:i+len(sub)], sub) {
			return i
		}
	}
	return -1
}

func equalFold(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		if toLower(a[i]) != toLower(b[i]) {
			return false
		}
	}
	return true
}

func toLower(c byte) byte {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}
