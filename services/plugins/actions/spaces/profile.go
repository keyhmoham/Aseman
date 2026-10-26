package spaces

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/posts/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	"github.com/aseman/aseman/plugins/actions/spaces/models/invitation"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/permission"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// SpaceProfile assembles a workspace's public profile: description, owner,
// member/room/agent/post/file counts and room names.
func (s *Service) SpaceProfile(ctx context.Context, spaceID identity.ID) (map[string]any, error) {
	sp, err := s.GetSpace(ctx, spaceID)
	if err != nil {
		return nil, err
	}
	ownerHandle := ""
	if sp.OwnerID != (identity.ID{}) {
		var acc account.Account
		if s.R.Get(ctx, "accounts", sp.OwnerID, &acc) == nil {
			ownerHandle = acc.Handle
		}
	}
	var mems []membership.Membership
	_ = s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "room_id": zeroRoom},
	}, &mems)
	memberCount := 0
	for i := range mems {
		if mems[i].Role != membership.RoleBot {
			memberCount++
		}
	}
	var bots []membership.Membership
	_ = s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "room_id": zeroRoom, "role": string(membership.RoleBot)},
	}, &bots)
	var rooms []space.Room
	_ = s.R.List(ctx, "rooms", database.Filter{Equal: map[string]any{"space_id": spaceID.String()}, OrderBy: "created_at", Asc: true}, &rooms)
	rooms = visibleRooms(rooms)
	roomNames := make([]string, 0, len(rooms))
	for i := range rooms {
		roomNames = append(roomNames, rooms[i].Name)
	}
	var posts []post.Post
	_ = s.R.List(ctx, "posts", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "parent_id": identity.ID{}.String()}, Limit: 1,
	}, &posts)
	postCount := 0
	if len(posts) > 0 {
		// Count without paging (bounded for profile display).
		var all []post.Post
		if s.R.List(ctx, "posts", database.Filter{Equal: map[string]any{"space_id": spaceID.String(), "parent_id": identity.ID{}.String()}}, &all) == nil {
			postCount = len(all)
		}
	}
	var files []filedata.File
	_ = s.R.List(ctx, "files", database.Filter{Equal: map[string]any{"space_id": spaceID.String()}}, &files)
	meta := map[string]any{}
	if m, merr := s.M.Get(ctx, sp.ID); merr == nil && m != nil {
		meta = m.Tree
	}
	return map[string]any{
		"id": sp.ID.String(), "name": sp.Name, "description": sp.Description,
		"public": sp.Public, "home": sp.Home,
		"owner_id": sp.OwnerID.String(), "owner_handle": ownerHandle,
		"member_count": memberCount, "agent_count": len(bots),
		"room_count": len(rooms), "rooms": roomNames,
		"post_count": postCount, "file_count": len(files),
		"metadata": meta, "avatar": helper.TreeAvatar(meta), "created_at": sp.CreatedAt,
	}, nil
}

// RoomProfile assembles a room's profile: its space, member/agent/message/file
// counts and the most recent messages.
func (s *Service) RoomProfile(ctx context.Context, roomID identity.ID) (map[string]any, error) {
	room, err := s.GetRoom(ctx, roomID)
	if err != nil {
		return nil, err
	}
	spaceName := ""
	if sp, serr := s.GetSpace(ctx, room.SpaceID); serr == nil {
		spaceName = sp.Name
	}
	var mems []membership.Membership
	_ = s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": room.SpaceID.String(), "room_id": roomID.String()},
	}, &mems)
	memberCount, agentCount := 0, 0
	for i := range mems {
		if mems[i].Role == membership.RoleBot {
			agentCount++
		} else {
			memberCount++
		}
	}
	var msgs []message.Message
	_ = s.R.List(ctx, "messages", database.Filter{
		Equal:   map[string]any{"space_id": room.SpaceID.String(), "room_id": roomID.String()},
		OrderBy: "created_at", Asc: false, Limit: 500,
	}, &msgs)
	recent := make([]map[string]any, 0, 5)
	handles := map[identity.ID]string{}
	for i := range msgs {
		if i >= 5 {
			break
		}
		sender := msgs[i].SenderID
		handle, seen := handles[sender]
		if !seen {
			var acc account.Account
			if s.R.Get(ctx, "accounts", sender, &acc) == nil {
				handle = acc.Handle
			}
			handles[sender] = handle
		}
		recent = append(recent, map[string]any{
			"sender_id": sender.String(), "sender_handle": handle,
			"body": msgs[i].Body, "created_at": msgs[i].CreatedAt,
		})
	}
	var files []filedata.File
	_ = s.R.List(ctx, "files", database.Filter{
		Equal: map[string]any{"space_id": room.SpaceID.String(), "room_id": roomID.String()},
	}, &files)
	return map[string]any{
		"id": room.ID.String(), "space_id": room.SpaceID.String(), "space_name": spaceName,
		"name": room.Name, "topic": room.Topic,
		"member_count": memberCount, "agent_count": agentCount,
		"message_count": len(msgs), "file_count": len(files),
		"recent_messages": recent, "created_at": room.CreatedAt,
	}, nil
}

// Join adds the caller to a space. Every project is private: joining takes a
// pending invitation (which is accepted).
func (s *Service) Join(ctx context.Context, caller, spaceID identity.ID) error {
	if caller.IsZero() {
		return errs.Unauthenticated("authentication required")
	}
	if _, err := s.GetSpace(ctx, spaceID); err != nil {
		return err
	}
	// Already a space-level member.
	if _, err := s.SpaceMembership(ctx, spaceID, caller); err == nil {
		return nil
	}
	var invites []invitation.Invitation
	if err := s.R.List(ctx, "invitations", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "invitee_id": caller.String(), "status": string(invitation.StatusPending)},
	}, &invites); err != nil {
		return err
	}
	if len(invites) == 0 {
		return errs.Permission("space is private — you need an invitation to join")
	}
	return s.AcceptInvitation(ctx, caller, invites[0].ID)
}

// spaceProfileAction implements spaces.space_profile.
type spaceProfileAction struct{ s *Service }

func (a *spaceProfileAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "space_profile", Summary: "Rich profile for a workspace"}
}
func (a *spaceProfileAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Space string `json:"space"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	// Projects are private: only their members can view them.
	if err := a.s.Can(ctx, id, identity.ID{}, req.Caller.ID, permission.SpaceView); err != nil {
		return nil, err
	}
	profile, err := a.s.SpaceProfile(ctx, id)
	if err != nil {
		return nil, err
	}
	// Is the caller a member? (drives the join/unjoin action)
	_, memberErr := a.s.SpaceMembership(ctx, id, req.Caller.ID)
	profile["am_member"] = memberErr == nil
	if memberErr != nil {
		profile["metadata"] = map[string]any{}
		if view, e := a.s.M.View(ctx, identity.ID{}, id); e == nil {
			profile["metadata"] = view.Tree
		}
	}
	return helper.JSON(profile)
}

// roomProfileAction implements spaces.room_profile.
type roomProfileAction struct{ s *Service }

func (a *roomProfileAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "room_profile", Summary: "Rich profile for a room"}
}
func (a *roomProfileAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Room string `json:"room"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Room)
	if err != nil {
		return nil, errs.InvalidArgument("invalid room id")
	}
	room, err := a.s.GetRoom(ctx, id)
	if err != nil {
		return nil, err
	}
	profile, err := a.s.RoomProfile(ctx, id)
	if err != nil {
		return nil, err
	}
	profile["am_member"] = a.s.Can(ctx, room.SpaceID, id, req.Caller.ID, permission.RoomRead) == nil
	return helper.JSON(profile)
}

// joinAction implements spaces.join: join a public space or accept an invite.
type joinAction struct{ s *Service }

func (a *joinAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "join", Summary: "Join a public workspace (or accept an invitation)"}
}
func (a *joinAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
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
		return nil, errs.InvalidArgument("invalid space id")
	}
	if err := a.s.Join(ctx, req.Caller.ID, id); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "joined": true})
}

// leaveAction implements spaces.leave: a member leaves a workspace (removing
// their space-level and per-room memberships). Owners cannot leave — they must
// delete the space instead.
type leaveAction struct{ s *Service }

func (a *leaveAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "leave", Summary: "Leave a workspace (owners must delete it instead)"}
}
func (a *leaveAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
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
		return nil, errs.InvalidArgument("invalid space id")
	}
	target, err := a.s.SpaceMembership(ctx, id, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	if target.IsOwner() {
		return nil, errs.Permission("owners cannot leave their workspace — delete it instead")
	}
	if err := a.s.R.Delete(ctx, "memberships", target.ID); err != nil {
		return nil, err
	}
	// Drop any per-room memberships the caller held in the space too.
	var rooms []membership.Membership
	if err := a.s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": id.String(), "member_id": req.Caller.ID.String()},
	}, &rooms); err == nil {
		for i := range rooms {
			if rooms[i].RoomID.IsZero() {
				continue
			}
			_ = a.s.R.Delete(ctx, "memberships", rooms[i].ID)
		}
	}
	return helper.JSON(map[string]any{"ok": true, "left": true})
}
