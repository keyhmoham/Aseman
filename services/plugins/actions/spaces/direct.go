package spaces

import (
	"context"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/jsonpatch"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// A direct conversation is a space of its own with a single room, shared by
// two accounts: two people, or a person and an agent. It has everything a
// project room has (files, agents, the sandbox), but it never shows up among
// the person's projects and the aseman lead does not join it. Writing to an
// agent in its direct room addresses that agent without an explicit mention.

// directMu serializes the creation of direct spaces so two first messages
// sent at once open the same conversation.
var directMu sync.Mutex

// directKey names an account pair independently of who opened it.
func directKey(a, b identity.ID) string {
	x, y := a.String(), b.String()
	if y < x {
		x, y = y, x
	}
	return x + ":" + y
}

// directFoundingPeer is the other account named by a Direct space's key —
// the original conversation peer (person or agent). Self-chats and non-directs
// have none. Extra agents installed later are not the founding peer.
func (s *Service) directFoundingPeer(ctx context.Context, sp *space.Space, caller identity.ID) (identity.ID, bool) {
	if sp == nil || !sp.Direct || sp.DirectKey == "" {
		return identity.ID{}, false
	}
	parts := strings.Split(sp.DirectKey, ":")
	if len(parts) != 2 {
		return identity.ID{}, false
	}
	a, errA := identity.Parse(parts[0])
	b, errB := identity.Parse(parts[1])
	if errA != nil || errB != nil {
		return identity.ID{}, false
	}
	if a == b {
		return identity.ID{}, false // personal Aseman self-chat
	}
	caller = s.botAccountOf(ctx, caller)
	switch {
	case a == caller:
		return b, true
	case b == caller:
		return a, true
	default:
		return identity.ID{}, false
	}
}

func directActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "spaces", Name: "direct_open", Summary: "Open (or start) the direct conversation with a person or an agent", Handler: s.directOpen},
		helper.Action{Namespace: "spaces", Name: "chat_list", Summary: "List my conversations: direct chats and project rooms, latest first", Handler: s.chatList},
	}
}

// OpenDirect returns the direct space between two accounts and its room,
// creating it on first use. The person of the pair owns it; an agent joins it
// as a bot so it answers there like in any room.
func (s *Service) OpenDirect(ctx context.Context, caller, peer identity.ID) (*space.Space, *space.Room, error) {
	sp, room, _, err := s.openDirect(ctx, caller, peer)
	return sp, room, err
}

// openDirect is OpenDirect that also reports whether the conversation was
// created by this call (its history was then imported).
func (s *Service) openDirect(ctx context.Context, caller, peer identity.ID) (*space.Space, *space.Room, bool, error) {
	if caller.IsZero() {
		return nil, nil, false, errs.Unauthenticated("authentication required")
	}
	peer = s.botAccountOf(ctx, peer)
	if peer.IsZero() {
		return nil, nil, false, errs.InvalidArgument("choose someone to talk to")
	}
	if peer == caller {
		return s.openSaved(ctx, caller)
	}
	var callerAcc, peerAcc account.Account
	if err := s.R.Get(ctx, "accounts", caller, &callerAcc); err != nil {
		return nil, nil, false, errs.NotFound("account not found")
	}
	if err := s.R.Get(ctx, "accounts", peer, &peerAcc); err != nil {
		return nil, nil, false, errs.NotFound("that account is not on this node")
	}
	if callerAcc.IsBot() && peerAcc.IsBot() {
		return nil, nil, false, errs.InvalidArgument("a direct conversation needs a person")
	}
	// Personal Aseman (built-in assistant / lead) lives in the self-chat —
	// never a separate person↔Aseman Direct.
	if person, ok := s.builtinAsemanPerson(ctx, callerAcc, peerAcc, caller, peer); ok {
		return s.openSaved(ctx, person)
	}
	// People use apps in their projects; they do not chat with one.
	if peerAcc.IsBot() && s.Bots != nil {
		if rec, err := s.botForMember(ctx, peer); err == nil && isAppBot(rec) {
			return nil, nil, false, errs.Permission(rec.Name + " is an app: use it in a project, or ask an agent to")
		}
	}
	key := directKey(caller, peer)
	directMu.Lock()
	defer directMu.Unlock()
	if sp := s.findDirect(ctx, key); sp != nil {
		room, err := s.generalRoom(ctx, sp.ID)
		if err != nil {
			return nil, nil, false, err
		}
		return sp, room, false, nil
	}
	owner, other, otherAcc := caller, peer, peerAcc
	if callerAcc.IsBot() {
		owner, other, otherAcc = peer, caller, callerAcc
	}
	sp, err := s.createSpace(ctx, owner, "Direct", "Direct conversation", key)
	if err != nil {
		return nil, nil, false, err
	}
	if otherAcc.IsBot() {
		err = s.AddBot(ctx, owner, sp.ID, identity.ID{}, other)
	} else {
		err = s.addDirectMember(ctx, sp.ID, other)
	}
	if err != nil {
		_ = s.R.Delete(ctx, "spaces", sp.ID)
		return nil, nil, false, err
	}
	room, err := s.generalRoom(ctx, sp.ID)
	if err != nil {
		return nil, nil, false, err
	}
	s.importDirectHistory(ctx, sp.ID, room.ID, caller, peer)
	return sp, room, true, nil
}

// openSaved is a person's Aseman chat: a direct chat with themselves, for
// notes, links and files, and the personal Aseman assistant. Like any room,
// other agents added to it answer when mentioned.
func (s *Service) openSaved(ctx context.Context, caller identity.ID) (*space.Space, *space.Room, bool, error) {
	var acc account.Account
	if err := s.R.Get(ctx, "accounts", caller, &acc); err != nil {
		return nil, nil, false, errs.NotFound("account not found")
	}
	if acc.IsBot() {
		return nil, nil, false, errs.InvalidArgument("choose someone else to talk to")
	}
	key := directKey(caller, caller)
	directMu.Lock()
	defer directMu.Unlock()
	created := false
	sp := s.findDirect(ctx, key)
	if sp == nil {
		var err error
		if sp, err = s.createSpace(ctx, caller, "Aseman", "Your personal Aseman", key); err != nil {
			return nil, nil, false, err
		}
		created = true
	}
	room, err := s.generalRoom(ctx, sp.ID)
	if err != nil {
		return nil, nil, false, err
	}
	return sp, room, created, nil
}

// builtinAsemanPerson reports the person whose Aseman self-chat should be used
// when either side of a proposed Direct is the built-in assistant or lead.
func (s *Service) builtinAsemanPerson(ctx context.Context, callerAcc, peerAcc account.Account, caller, peer identity.ID) (identity.ID, bool) {
	if s.Bots == nil {
		return identity.ID{}, false
	}
	if peerAcc.IsBot() && !callerAcc.IsBot() {
		if rec, err := s.botForMember(ctx, peer); err == nil && rec.IsBuiltin() {
			return caller, true
		}
	}
	if callerAcc.IsBot() && !peerAcc.IsBot() {
		if rec, err := s.botForMember(ctx, caller); err == nil && rec.IsBuiltin() {
			return peer, true
		}
	}
	return identity.ID{}, false
}

// isBuiltinDirectPeer reports whether a direct chat's other member is the
// built-in Aseman assistant or lead (legacy separate chats to hide).
func (s *Service) isBuiltinDirectPeer(ctx context.Context, peer identity.ID) bool {
	if s.Bots == nil || peer.IsZero() {
		return false
	}
	rec, err := s.botForMember(ctx, peer)
	return err == nil && rec.IsBuiltin()
}

func (s *Service) findDirect(ctx context.Context, key string) *space.Space {
	var list []space.Space
	if err := s.R.List(ctx, "spaces", database.Filter{Equal: map[string]any{"direct_key": key}, Limit: 1}, &list); err != nil || len(list) == 0 {
		return nil
	}
	return &list[0]
}

func (s *Service) addDirectMember(ctx context.Context, spaceID, member identity.ID) error {
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	return s.R.CreateID(ctx, "memberships", id, &membership.Membership{
		Entity:  entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		SpaceID: spaceID, MemberID: member, Role: membership.RoleMember, JoinedAt: now,
	})
}

// importDirectHistory copies the pair's earlier direct messages (sent before
// conversations were rooms) into the new room, keeping their times.
func (s *Service) importDirectHistory(ctx context.Context, spaceID, roomID, a, b identity.ID) {
	var old []message.Direct
	for _, pair := range [][2]identity.ID{{a, b}, {b, a}} {
		var part []message.Direct
		if err := s.R.List(ctx, "directs", database.Filter{
			Equal:   map[string]any{"from_id": pair[0].String(), "to_id": pair[1].String()},
			OrderBy: "created_at", Asc: false, Limit: 200,
		}, &part); err == nil {
			old = append(old, part...)
		}
	}
	for _, dm := range old {
		id, err := identity.New(s.K.NodeID())
		if err != nil {
			return
		}
		m := &message.Message{
			Entity:  entity.Entity{ID: id, CreatedAt: dm.CreatedAt, UpdatedAt: dm.CreatedAt},
			SpaceID: spaceID, RoomID: roomID, SenderID: dm.From, Body: dm.Body, Kind: message.KindMessage,
		}
		m.SetMentions(nil)
		_ = s.R.CreateID(ctx, "messages", id, m)
	}
}

// PostDirect mirrors a message sent through users.dm_send into the pair's
// direct room, so the conversation reads the same in the messenger. It does
// not start the agent: dm_send already delivers the message to it.
// directID (optional) is stamped on the room message for dm_react / hide / keep.
func (s *Service) PostDirect(ctx context.Context, from, to identity.ID, body string, directID identity.ID) error {
	sp, room, created, err := s.openDirect(ctx, from, to)
	if err != nil || created {
		// A new conversation already imported the message with its history.
		return err
	}
	if blocked, byMe := s.directBlock(ctx, sp.ID, from); blocked {
		return blockError(byMe)
	}
	return s.stampDirectMessage(ctx, sp.ID, room.ID, from, body, directID)
}

// PostSavedAnswer posts a personal Aseman reply into the person's Aseman chat
// as the chat assistant. Brain answers must not open a separate person↔assistant
// Direct: that left Talk / notes showing only the assistant side there, and
// user notes only in the Aseman self-chat.
//
// The assistant is not added as a space member: the Aseman chat is identified as
// a self-chat by having no other members, and enrichMessages still resolves the
// sender account (kind=bot) for display.
func (s *Service) PostSavedAnswer(ctx context.Context, person, assistant identity.ID, body string, directID identity.ID) error {
	if person.IsZero() || assistant.IsZero() {
		return errs.InvalidArgument("person and assistant are required")
	}
	sp, room, _, err := s.openSaved(ctx, person)
	if err != nil {
		return err
	}
	return s.stampDirectMessage(ctx, sp.ID, room.ID, assistant, body, directID)
}

func (s *Service) stampDirectMessage(ctx context.Context, spaceID, roomID, sender identity.ID, body string, directID identity.ID) error {
	msgID, err := s.storeRoomMessage(ctx, spaceID, roomID, sender, body, message.KindMessage, "")
	if err != nil || directID.IsZero() {
		return err
	}
	msg := &message.Message{}
	if err := s.R.Get(ctx, "messages", msgID, msg); err != nil {
		return nil
	}
	msg.DirectID = directID.String()
	msg.UpdatedAt = time.Now().UTC()
	_ = s.R.Update(ctx, "messages", msgID, msg)
	return nil
}

// directPeers lists the members of a direct space other than the caller.
func (s *Service) directPeers(ctx context.Context, spaceID, caller identity.ID) []identity.ID {
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{Equal: map[string]any{"space_id": spaceID.String()}}, &mems); err != nil {
		return nil
	}
	seen := map[identity.ID]bool{caller: true}
	out := []identity.ID{}
	for _, m := range mems {
		if seen[m.MemberID] {
			continue
		}
		seen[m.MemberID] = true
		out = append(out, m.MemberID)
	}
	return out
}

// noteDmInstall records that [installer] added [botAccount] in a direct chat.
// Each participant keeps their own agents/apps; the peer of a person↔agent
// DM is always visible without this record.
func (s *Service) noteDmInstall(ctx context.Context, spaceID, installer, botAccount identity.ID) {
	if s.M == nil || installer.IsZero() || botAccount.IsZero() {
		return
	}
	sp, err := s.GetSpace(ctx, spaceID)
	if err != nil || sp == nil || !sp.Direct {
		return
	}
	botAccount = s.botAccountOf(ctx, botAccount)
	_ = s.M.Patch(ctx, spaceID, jsonpatch.Patch{{
		Op:    "set",
		Path:  "dm_installs/" + installer.String() + "/" + botAccount.String(),
		Value: true,
	}})
}

// clearDmInstall drops a bot from the caller's personal DM install set.
func (s *Service) clearDmInstall(ctx context.Context, spaceID, installer, botAccount identity.ID) {
	if s.M == nil || installer.IsZero() || botAccount.IsZero() {
		return
	}
	botAccount = s.botAccountOf(ctx, botAccount)
	_ = s.M.Patch(ctx, spaceID, jsonpatch.Patch{{
		Op:   "remove",
		Path: "dm_installs/" + installer.String() + "/" + botAccount.String(),
	}})
}

// dmInstallVisible reports whether [botAccount] should appear in the caller's
// DM bot list: the conversation peer, or something this caller installed.
func (s *Service) dmInstallVisible(ctx context.Context, spaceID, caller, botAccount identity.ID) bool {
	botAccount = s.botAccountOf(ctx, botAccount)
	for _, peer := range s.directPeers(ctx, spaceID, caller) {
		if peer == botAccount || s.botAccountOf(ctx, peer) == botAccount {
			return true
		}
	}
	if s.M == nil {
		return true // no metadata: keep prior shared behaviour
	}
	rec, err := s.M.Get(ctx, spaceID)
	if err != nil || rec == nil {
		return true
	}
	root, _ := rec.Tree["dm_installs"].(map[string]any)
	mine, _ := root[caller.String()].(map[string]any)
	// No personal install set yet: keep prior shared memberships visible.
	if mine == nil {
		return true
	}
	_, ok := mine[botAccount.String()]
	return ok
}

func (s *Service) directOpen(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Peer string `json:"peer"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	peer, err := identity.Parse(strings.TrimSpace(in.Peer))
	if err != nil {
		return nil, errs.InvalidArgument("invalid peer id")
	}
	sp, room, err := s.OpenDirect(ctx, req.Caller.ID, peer)
	if err != nil {
		return nil, err
	}
	out := map[string]any{
		"space_id": sp.ID.String(), "room_id": room.ID.String(), "room_name": room.Name,
		"space_name": sp.Name, "peer": s.participants().get(ctx, s.botAccountOf(ctx, peer)),
	}
	if mem, err := s.SpaceMembership(ctx, sp.ID, req.Caller.ID); err == nil {
		out["role"] = mem.Role
	}
	return helper.JSON(out)
}

// chatList is the messenger's inbox: every direct conversation and every room
// of the caller's projects, each with its latest message, newest first.
func (s *Service) chatList(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Kind string `json:"kind,omitempty"` // "direct", "room" or empty for both
		// Query keeps the direct chats whose other side's name or handle
		// holds it, and the rooms whose name or project's name does.
		Query string `json:"query,omitempty"`
	}
	_ = helper.Decode(req, &in)
	q := strings.ToLower(strings.TrimSpace(in.Query))
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{
		Equal:   map[string]any{"member_id": req.Caller.ID.String(), "room_id": zeroRoom},
		OrderBy: "created_at", Asc: false, Limit: 500,
	}, &mems); err != nil {
		return nil, err
	}
	people := s.participants()
	chats := []map[string]any{}
	for _, m := range mems {
		sp, err := s.GetSpace(ctx, m.SpaceID)
		if err != nil {
			continue
		}
		if (in.Kind == "direct" && !sp.Direct) || (in.Kind == "room" && sp.Direct) {
			continue
		}
		var rooms []space.Room
		filter := database.Filter{Equal: map[string]any{"space_id": sp.ID.String()}, OrderBy: "created_at", Asc: true}
		if sp.Direct {
			filter.Limit = 1
		}
		if err := s.R.List(ctx, "rooms", filter, &rooms); err != nil {
			continue
		}
		rooms = visibleRooms(rooms)
		seen := s.SeenAt(ctx, req.Caller.ID, sp.ID)
		tree := s.chatTree(ctx, sp.ID)
		cleared := time.Time{}
		if sp.Direct {
			cleared = clearedIn(tree, req.Caller.ID)
		}
		for _, room := range rooms {
			row := map[string]any{
				"kind": "room", "space_id": sp.ID.String(), "space_name": sp.Name,
				"room_id": room.ID.String(), "room_name": room.Name, "home": sp.Home, "role": m.Role,
				"updated_at": room.CreatedAt, "space_avatar": helper.TreeAvatar(tree),
			}
			if sp.Direct {
				row["kind"] = "direct"
				if peers := s.directPeers(ctx, sp.ID, req.Caller.ID); len(peers) > 0 {
					// Built-in Aseman lives in the self-chat; hide legacy
					// person↔assistant / lead Directs from the inbox.
					if s.isBuiltinDirectPeer(ctx, peers[0]) {
						continue
					}
					row["peer"] = people.get(ctx, peers[0])
					mine, theirs := blockedIn(tree, req.Caller.ID), blockedIn(tree, peers[0])
					if mine {
						row["blocked"] = true
					}
					if mine || theirs {
						row["can_send"] = false
					}
				} else {
					row["saved"] = true
					row["peer"] = people.get(ctx, req.Caller.ID)
				}
			}
			if q != "" && !chatMatches(row, q) {
				continue
			}
			if at := pinnedIn(tree, req.Caller.ID, room.ID); !at.IsZero() {
				row["pinned_at"] = at
			}
			if len(typingIn(room.ID, req.Caller.ID)) > 0 {
				row["typing"] = true
			}
			last := s.lastRoomMessage(ctx, room.ID)
			if last != nil && !cleared.IsZero() && !last.CreatedAt.After(cleared) {
				last = nil // deleted for the caller: it returns with a newer message
				if row["pinned_at"] == nil {
					continue
				}
			}
			if last != nil {
				body := last.Body
				if r := []rune(body); len(r) > 200 {
					body = string(r[:200])
				}
				row["last"] = map[string]any{
					"id": last.ID.String(), "body": body, "sender": people.get(ctx, last.SenderID),
					"attachments": len(last.ParseAttachments()), "created_at": last.CreatedAt,
				}
				row["updated_at"] = last.CreatedAt
			}
			if !seen.IsZero() {
				row["seen_at"] = seen
			}
			unread := database.Filter{
				Equal: map[string]any{"room_id": room.ID.String()},
				In:    map[string][]any{"kind": {"", message.KindMessage}},
			}
			if !seen.IsZero() {
				unread.GreaterThan = map[string]any{"created_at": seen.UTC()}
			}
			if n, err := s.R.Count(ctx, "messages", unread); err == nil {
				row["unread"] = n
			}
			if _, _, ok := s.RoomActivity(room.ID); ok {
				row["working"] = true
			}
			chats = append(chats, row)
		}
	}
	// Pinned chats first, the latest pinned on top; the rest newest first.
	sort.SliceStable(chats, func(i, j int) bool {
		pi, _ := chats[i]["pinned_at"].(time.Time)
		pj, _ := chats[j]["pinned_at"].(time.Time)
		if pi.IsZero() != pj.IsZero() {
			return !pi.IsZero()
		}
		if !pi.IsZero() {
			return pi.After(pj)
		}
		a, _ := chats[i]["updated_at"].(time.Time)
		b, _ := chats[j]["updated_at"].(time.Time)
		return a.After(b)
	})
	return helper.JSON(map[string]any{"chats": chats})
}

// chatMatches reports whether a chat row's names hold the lowercase query: a
// direct chat's other side (display name or handle), a room's own name or its
// project's.
func chatMatches(row map[string]any, q string) bool {
	names := []string{}
	if row["kind"] == "direct" {
		if peer, ok := row["peer"].(map[string]any); ok {
			for _, key := range []string{"display_name", "handle"} {
				if v, _ := peer[key].(string); v != "" {
					names = append(names, v)
				}
			}
		}
	} else {
		for _, key := range []string{"room_name", "space_name"} {
			if v, _ := row[key].(string); v != "" {
				names = append(names, v)
			}
		}
	}
	for _, name := range names {
		if strings.Contains(strings.ToLower(name), q) {
			return true
		}
	}
	return false
}

// lastRoomMessage is the latest conversation message of a room (logs and tool
// output are not part of the conversation's preview).
func (s *Service) lastRoomMessage(ctx context.Context, roomID identity.ID) *message.Message {
	var recent []message.Message
	if err := s.R.List(ctx, "messages", database.Filter{
		Equal: map[string]any{"room_id": roomID.String()}, OrderBy: "created_at", Asc: false, Limit: 8,
	}, &recent); err != nil {
		return nil
	}
	for i := range recent {
		if recent[i].Kind == message.KindLog || recent[i].Kind == message.KindTool {
			continue
		}
		return &recent[i]
	}
	return nil
}

// directMentions addresses the agent of a direct conversation: a person's
// message there is meant for it even without an explicit mention.
func (s *Service) directMentions(ctx context.Context, spaceID, sender identity.ID, mentions []string) []string {
	if len(mentions) > 0 || s.isBotAccount(ctx, sender) {
		return mentions
	}
	sp, err := s.GetSpace(ctx, spaceID)
	if err != nil || !sp.Direct {
		return mentions
	}
	for _, peer := range s.directPeers(ctx, spaceID, sender) {
		if rec, err := s.botForMember(ctx, peer); err == nil && isAgentRuntime(rec) {
			mentions = append(mentions, rec.AccountID.String())
		}
	}
	return mentions
}
