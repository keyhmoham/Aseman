// Package permission defines the canonical permission keys used across spaces,
// rooms and bots. Permissions are strings resolved against role defaults plus
// per-membership grants.
package permission

// Space-level permissions.
const (
	// SpaceView allows reading the space, its public metadata and member list.
	SpaceView = "space.view"
	// SpaceEditMetadata allows modifying the space metadata tree.
	SpaceEditMetadata = "space.edit_metadata"
	// SpaceInvite allows inviting accounts to the space.
	SpaceInvite = "space.invite"
	// SpaceRemove allows removing members from the space.
	SpaceRemove = "space.remove"
	// SpaceManageBots allows adding/removing bots to/from the space.
	SpaceManageBots = "space.manage_bots"
	// SpaceManageMembers allows modifying other members' permissions (non-owner/admin).
	SpaceManageMembers = "space.manage_members"
	// SpaceManageRooms allows creating/deleting rooms.
	SpaceManageRooms = "space.manage_rooms"
	// SpaceManageFiles allows uploading/deleting any file in the space.
	SpaceManageFiles = "space.manage_files"
	// SpaceManageMessages allows deleting any message in the space.
	SpaceManageMessages = "space.manage_messages"
)

// Room-level permissions.
const (
	RoomSend        = "room.send"        // send messages in the room
	RoomRead        = "room.read"        // read messages in the room
	RoomEditMeta    = "room.edit_meta"   // modify room metadata
	RoomManageBots  = "room.manage_bots" // add/remove bots in the room
	RoomUpload      = "room.upload"      // upload files to the room
	RoomEditFiles   = "room.edit_files"  // modify files in the room
	RoomDeleteFiles = "room.delete_files"
	RoomKV          = "room.kv"     // read/write bot KV store scoped to the room
	RoomManage      = "room.manage" // administer the room (rename, delete)
)

// Bot-level permissions (what a user may do with a specific bot).
const (
	BotMessage    = "bot.message" // message the bot directly
	BotAddToSpace = "bot.add_to_space"
	BotManage     = "bot.manage" // start/stop/pause the bot VM
)

// RoleDefaults returns the permission set granted by a role.
func RoleDefaults(role string) []string {
	switch role {
	case "owner":
		return []string{"*"}
	case "admin":
		return []string{
			SpaceView, SpaceEditMetadata, SpaceInvite, SpaceRemove, SpaceManageBots,
			SpaceManageMembers, SpaceManageRooms, SpaceManageFiles, SpaceManageMessages,
			RoomSend, RoomRead, RoomEditMeta, RoomManageBots, RoomUpload, RoomEditFiles,
			RoomDeleteFiles, RoomKV, RoomManage, BotMessage, BotAddToSpace, BotManage,
		}
	case "bot":
		return []string{
			SpaceView, RoomSend, RoomRead, RoomKV, RoomUpload, RoomEditFiles,
			RoomDeleteFiles, BotMessage,
		}
	case "guest", "viewer":
		return []string{SpaceView, RoomRead}
	case "member":
		return []string{
			SpaceView,
			RoomSend, RoomRead, RoomUpload, RoomEditFiles, RoomDeleteFiles, RoomKV,
			BotMessage,
		}
	default:
		return nil
	}
}

// Resolve merges role defaults with explicit grants: membership permissions
// add to defaults; the special "*" grants everything.
func Resolve(role string, grants []string) func(string) bool {
	defs := RoleDefaults(role)
	grantAll := false
	granted := map[string]struct{}{}
	for _, g := range grants {
		if g == "*" {
			grantAll = true
		}
		granted[g] = struct{}{}
	}
	return func(p string) bool {
		if grantAll {
			return true
		}
		for _, d := range defs {
			if d == p || d == "*" {
				return true
			}
		}
		_, ok := granted[p]
		return ok
	}
}
