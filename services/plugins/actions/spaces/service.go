// Package spaces implements the spaces namespace: spaces, rooms, memberships,
// invitations, permissions, messages, files and per-bot key-value storage.
package spaces

import (
	"context"
	devmodels "github.com/aseman/aseman/plugins/actions/developer/models"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/spaces/models/invitation"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/permission"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/kvs"
	"github.com/aseman/aseman/plugins/actions/support/metasvc"
	"github.com/aseman/aseman/plugins/actions/support/models/metadata"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// zeroRoom is the universal id string of a zero room id (space-level rows).
const zeroRoom = "00000000000000000000000000000000"

// Service implements space operations and permission resolution.
type Service struct {
	// agentMemoryFn replaces the agent runtime's memory (tests).
	agentMemoryFn func() vmm.EngineMemory
	// frontendLookup replaces the developer namespace's platform frontends
	// (tests; platform_frontend.go).
	frontendLookup func(context.Context, string, identity.ID) (*devmodels.PlatformFrontend, error)
	// homeMu keeps two first uses from making two home workspaces.
	homeMu sync.Mutex
	teams  teamRuns
	desks  deskStore
	// threadRooms caches which room each room id is a thread of (see threads.go).
	threadRooms     sync.Map
	botMembershipMu sync.Mutex
	K               api.Kernel
	R               *repo.Repo
	M               *metasvc.Service
	KV              *kvs.Service
	L               *logger.Logger

	// Bots is injected by the composition root so the shared per-space docker
	// sandbox can be provisioned on demand. The sandbox is a bot too.
	Bots BotPort

	// SandboxBackend is the shared per-space sandbox backbone ("docker" or
	// "modal"), wired from sandbox.backend in config. docker provisions one
	// standalone docker container per space; modal keeps using Modal remote
	// sandboxes. Empty means "docker".
	SandboxBackend   string
	SandboxImage     string
	SandboxResources bot.ResourceProfile
	proxyCreateMu    sync.Mutex

	// Routines is the per-room task scheduler (wired by the root); agents manage
	// routines through the routine_create/list/delete tools.
	Routines RoutineManager

	// Msg is the fire-and-forget message service (wired by the root); it lets
	// aseman send direct messages to individuals via the message_send tool.
	Msg MessagePort

	sandboxMu sync.Mutex
	// idleSeen is when the reaper first saw a running sandbox nothing times
	// (see reapIdleSandboxes), by bot id; guarded by sandboxMu.
	idleSeen          map[identity.ID]time.Time
	sandboxEnsureMu   sync.Mutex
	sandboxOperations sync.Map
	sandboxes         map[string]*sandboxState
	fileEditLocks     [64]sync.Mutex

	// activity is the live per-room agent status registry backing the chat's
	// working indicator: which agent is working in a room and what it is doing
	// right now. It is written by the agent runtime (via a status hook on the
	// context) and by the aseman orchestrator, and read by spaces.message_list.
	activityMu sync.Mutex
	activity   map[string]map[string]roomActivity
	// liveSeq counts changes to the live activity; liveCh is closed (and
	// replaced) on each one, which wakes everyone waiting in spaces.live.
	liveSeq uint64
	liveCh  chan struct{}

	// computerOps is what people asked each project's computer to do, by
	// space, while it does it; computerCh is closed (and replaced) whenever a
	// computer changes, which wakes everyone watching one (spaces.computer
	// watch). Both are guarded by computerMu.
	computerMu  sync.Mutex
	computerOps map[string]string
	computerCh  chan struct{}

	// hireFn replaces installing a marketplace listing in agent_hire (tests).
	hireFn func(ctx context.Context, owner, listingID, spaceID identity.ID) (identity.ID, error)

	// frontendWakes are the wakes of published platform frontends' computers,
	// one per preview (platform_wake.go); guarded by frontendWakeMu.
	frontendWakeMu sync.Mutex
	frontendWakes  map[identity.ID]*frontendWake
	// wakeOpenFn replaces ProxyOpen in those wakes (tests).
	wakeOpenFn func(ctx context.Context, id, actor identity.ID) (map[string]any, error)

	// clientBuilds are the builds of platforms' Android clients this node
	// watches, by platform slug (platform_client.go); guarded by clientBuildMu.
	clientBuildMu sync.Mutex
	clientBuilds  map[string]*clientBuild
	// Replacements in tests: the computer's shell, reading a file of it, the
	// developer namespace's record, and how often a build is looked at.
	clientExecFn    func(ctx context.Context, space identity.ID, command string) (string, error)
	clientReadFn    func(ctx context.Context, space identity.ID, path string) ([]byte, error)
	clientRecordFn  func(ctx context.Context, platformID string, c devmodels.PlatformClient) error
	clientPollEvery time.Duration
}

// roomActivity is the live status of the agent currently working in a room.
type roomActivity struct {
	Agent  string
	Detail string
	// Draft is the answer the agent is writing right now, as far as the model
	// has produced it. It is never stored: the finished reply is the message.
	Draft string
	At    time.Time
}

// activityTTL bounds how long a status stays visible after its last update, so
// a crashed handler can never leave a stale "working" indicator behind.
const activityTTL = 3 * time.Minute

// NewService builds the spaces service.
func NewService(k api.Kernel, r *repo.Repo, log *logger.Logger) *Service {
	return &Service{
		K: k, R: r,
		M:         &metasvc.Service{K: k, R: r},
		KV:        &kvs.Service{K: k, R: r},
		L:         log.Named("spaces"),
		sandboxes: map[string]*sandboxState{},
		activity:  map[string]map[string]roomActivity{},
	}
}

// SetRoomActivity records the live status of an agent working in a room;
// several agents can work in one room at once. An empty detail clears that
// agent's status (an empty agent clears the room). The chat polls it through
// spaces.updates.
func (s *Service) SetRoomActivity(_ context.Context, roomID identity.ID, agent, detail string) {
	if roomID.IsZero() {
		return
	}
	s.activityMu.Lock()
	defer s.activityMu.Unlock()
	if s.activity == nil {
		s.activity = map[string]map[string]roomActivity{}
	}
	room := roomID.String()
	defer s.liveChangedLocked()
	if agent == "" && detail == "" {
		delete(s.activity, room)
		return
	}
	if detail == "" {
		delete(s.activity[room], agent)
		return
	}
	if s.activity[room] == nil {
		s.activity[room] = map[string]roomActivity{}
	}
	s.activity[room][agent] = roomActivity{Agent: agent, Detail: detail, Draft: s.activity[room][agent].Draft, At: time.Now().UTC()}
}

// SetRoomDraft publishes the answer an agent is writing in a room, as far as
// it has got; an empty text withdraws it (the model turned to a tool instead).
// People following the room see it grow until the finished reply replaces it.
func (s *Service) SetRoomDraft(_ context.Context, roomID identity.ID, agent, text string) {
	if roomID.IsZero() || agent == "" {
		return
	}
	s.activityMu.Lock()
	defer s.activityMu.Unlock()
	room := roomID.String()
	cur, ok := s.activity[room][agent]
	if !ok && text == "" {
		return
	}
	if cur.Draft == text {
		return
	}
	if s.activity == nil {
		s.activity = map[string]map[string]roomActivity{}
	}
	if s.activity[room] == nil {
		s.activity[room] = map[string]roomActivity{}
	}
	if !ok {
		cur = roomActivity{Agent: agent, Detail: "writing…"}
	}
	cur.Draft, cur.At = text, time.Now().UTC()
	s.activity[room][agent] = cur
	s.liveChangedLocked()
}

// liveChangedLocked wakes everyone waiting for the live activity to change.
// The caller holds activityMu.
func (s *Service) liveChangedLocked() {
	s.liveSeq++
	if s.liveCh != nil {
		close(s.liveCh)
	}
	s.liveCh = make(chan struct{})
}

// liveWait returns the live activity's change counter and a channel that is
// closed at its next change.
func (s *Service) liveWait() (uint64, <-chan struct{}) {
	s.activityMu.Lock()
	defer s.activityMu.Unlock()
	if s.liveCh == nil {
		s.liveCh = make(chan struct{})
	}
	if s.liveSeq == 0 {
		s.liveSeq = 1 // 0 is a client that has not asked yet
	}
	return s.liveSeq, s.liveCh
}

// RoomActivities returns what each agent working in a room is doing now,
// most recent first, dropping stale entries.
func (s *Service) RoomActivities(roomID identity.ID) []roomActivity {
	s.activityMu.Lock()
	defer s.activityMu.Unlock()
	out := []roomActivity{}
	for agent, a := range s.activity[roomID.String()] {
		if time.Since(a.At) > activityTTL {
			delete(s.activity[roomID.String()], agent)
			continue
		}
		out = append(out, a)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].At.After(out[j].At) })
	return out
}

// RoomActivity returns the most recent live status in a room, if any.
func (s *Service) RoomActivity(roomID identity.ID) (agent, detail string, ok bool) {
	if all := s.RoomActivities(roomID); len(all) > 0 {
		return all[0].Agent, all[0].Detail, true
	}
	return "", "", false
}

// activityWriter installs a status hook on ctx that publishes into [roomID]'s
// live activity, and returns a cleanup that clears the statuses it published.
func (s *Service) activityWriter(ctx context.Context, roomID identity.ID) (context.Context, func()) {
	var mu sync.Mutex
	agents := map[string]bool{}
	wrapped := vmm.WithStatus(ctx, func(agent, detail string) {
		mu.Lock()
		agents[agent] = true
		mu.Unlock()
		s.SetRoomActivity(context.Background(), roomID, agent, detail)
	})
	return wrapped, func() {
		mu.Lock()
		defer mu.Unlock()
		for agent := range agents {
			s.SetRoomActivity(context.Background(), roomID, agent, "")
		}
	}
}

// ensureRoom resolves a zero room id to the space's first (general) room.
func (s *Service) ensureRoom(ctx context.Context, spaceID, roomID identity.ID) identity.ID {
	if !roomID.IsZero() {
		return roomID
	}
	room, err := s.generalRoom(ctx, spaceID)
	if err != nil {
		return identity.ID{}
	}
	return room.ID
}

// GetSpace loads a space by id.
func (s *Service) GetSpace(ctx context.Context, id identity.ID) (*space.Space, error) {
	sp := &space.Space{}
	if err := s.R.Get(ctx, "spaces", id, sp); err != nil {
		return nil, err
	}
	return sp, nil
}

// GetRoom loads a room.
func (s *Service) GetRoom(ctx context.Context, id identity.ID) (*space.Room, error) {
	r := &space.Room{}
	if err := s.R.Get(ctx, "rooms", id, r); err != nil {
		return nil, err
	}
	return r, nil
}

// SpaceMembership loads a caller's space-level membership (if any).
func (s *Service) SpaceMembership(ctx context.Context, spaceID, member identity.ID) (*membership.Membership, error) {
	var list []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "member_id": member.String(), "room_id": zeroRoom},
	}, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, errs.NotFound("no space membership")
	}
	return &list[0], nil
}

// RoomMembership loads a caller's room membership (if any).
func (s *Service) RoomMembership(ctx context.Context, spaceID, roomID, member identity.ID) (*membership.Membership, error) {
	var list []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "room_id": roomID.String(), "member_id": member.String()},
	}, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, errs.NotFound("no room membership")
	}
	return &list[0], nil
}

// Can checks whether caller holds perm in space (and optionally a room).
func (s *Service) Can(ctx context.Context, spaceID, roomID identity.ID, caller identity.ID, perm string) error {
	if caller.IsZero() {
		return errs.Unauthenticated("authentication required")
	}
	if _, err := s.GetSpace(ctx, spaceID); err != nil {
		return err
	}
	sm, err := s.SpaceMembership(ctx, spaceID, caller)
	if err != nil {
		return errs.Permission("not a member of space " + spaceID.String())
	}
	if sm.IsOwner() {
		return nil
	}
	// A thread is governed by its room's grants.
	roomID = s.mainRoom(ctx, roomID)
	// Merge room grants if the action is room-scoped.
	role := string(sm.Role)
	grants := sm.Permissions
	if !roomID.IsZero() {
		if rm, err := s.RoomMembership(ctx, spaceID, roomID, caller); err == nil {
			if rm.IsOwner() {
				return nil
			}
			if rm.Role == membership.RoleBot || rm.Role == membership.RoleAdmin {
				role = string(rm.Role)
			}
			grants = append(grants, rm.Permissions...)
		}
	}
	has := permission.Resolve(role, grants)
	if !has(perm) {
		return errs.Permission("missing permission " + perm)
	}
	return nil
}

// CreateSpace creates a space with a default room, metadata and owner membership.
func (s *Service) CreateSpace(ctx context.Context, owner identity.ID, name, description string) (*space.Space, error) {
	return s.createSpace(ctx, owner, name, description, "")
}

// createSpace creates a space with its first room. A non-empty directKey makes
// it a direct conversation, which the aseman lead does not join.
func (s *Service) createSpace(ctx context.Context, owner identity.ID, name, description, directKey string) (*space.Space, error) {
	if name == "" {
		return nil, errs.InvalidArgument("space name required")
	}
	node := s.K.NodeID()
	spID, err := identity.New(node)
	if err != nil {
		return nil, err
	}
	roomID, err := identity.New(node)
	if err != nil {
		return nil, err
	}
	memID, err := identity.New(node)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	sp := &space.Space{
		Entity:  entity.Entity{ID: spID, CreatedAt: now, UpdatedAt: now},
		OwnerID: owner, Name: name, Description: description,
		MetadataID: spID, Public: false,
		PlatformID: helper.EntityPlatform(ctx, s.R, owner),
		Direct:     directKey != "", DirectKey: directKey,
	}
	if err := s.R.CreateID(ctx, "spaces", spID, sp); err != nil {
		return nil, err
	}
	room := &space.Room{
		Entity:  entity.Entity{ID: roomID, CreatedAt: now, UpdatedAt: now},
		SpaceID: spID, Name: "general", MetadataID: roomID,
	}
	if err := s.R.CreateID(ctx, "rooms", roomID, room); err != nil {
		return nil, err
	}
	mem := &membership.Membership{
		Entity:  entity.Entity{ID: memID, CreatedAt: now, UpdatedAt: now},
		SpaceID: spID, MemberID: owner, Role: membership.RoleOwner, JoinedAt: now,
	}
	if err := s.R.CreateID(ctx, "memberships", memID, mem); err != nil {
		return nil, err
	}
	meta := &metadata.Record{
		Owner: spID.String(), Tree: metadata.Tree{"name": name, "description": description},
		PublicPaths: []string{}, Version: 1, UpdatedAt: now,
	}
	if err := s.R.CreateID(ctx, "metadatas", spID, meta); err != nil {
		return nil, err
	}
	if !sp.Direct {
		s.ensureAseman(ctx, spID)
	}
	return sp, nil
}

// CreateHomeSpace creates (or returns) the person's home: their personal
// Aseman chat. Handle is kept for callers; the space is always named Aseman.
func (s *Service) CreateHomeSpace(ctx context.Context, owner identity.ID, handle string) (*space.Space, error) {
	_ = handle
	sp, _, _, err := s.ensurePersonalHome(ctx, owner)
	return sp, err
}

// HomeSpace returns the home workspace of an account, if any.
func (s *Service) HomeSpace(ctx context.Context, owner identity.ID) (*space.Space, error) {
	var list []space.Space
	if err := s.R.List(ctx, "spaces", database.Filter{
		Equal: map[string]any{"owner_id": owner.String(), "home": true},
	}, &list); err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, errs.NotFound("no home space")
	}
	return &list[0], nil
}

// PersonalComputer is the space whose computer is a person's own: their home
// Aseman chat, made now if they have none yet. Their direct chats' agents and
// their personal Aseman work on it. Agents have no personal computer.
func (s *Service) PersonalComputer(ctx context.Context, person identity.ID) (*space.Space, error) {
	if person.IsZero() {
		return nil, errs.InvalidArgument("a personal computer needs a person")
	}
	if home, err := s.HomeSpace(ctx, person); err == nil && home != nil {
		if s.isPersonalHome(home, person) {
			return home, nil
		}
	}
	var acc account.Account
	if err := s.R.Get(ctx, "accounts", person, &acc); err != nil {
		return nil, err
	}
	if acc.Kind != account.KindUser || s.isBotAccount(ctx, person) {
		return nil, errs.NotFound("no personal computer")
	}
	home, _, _, err := s.ensurePersonalHome(ctx, person)
	if err != nil {
		return nil, errs.Wrap(errs.CodeUnavailable, err, "could not open the personal workspace")
	}
	return home, nil
}

// isPersonalHome reports whether sp is the person's Aseman home (self-Direct).
func (s *Service) isPersonalHome(sp *space.Space, person identity.ID) bool {
	return sp != nil && sp.Home && sp.Direct && sp.DirectKey == directKey(person, person)
}

// isSelfChat reports whether sp is the person's Aseman self-chat (home).
func (s *Service) isSelfChat(sp *space.Space, person identity.ID) bool {
	return sp != nil && sp.Direct && sp.DirectKey == directKey(person, person)
}

// healPersonalHome collapses a legacy project home and a separate Aseman
// self-chat when either already exists. It does not create one from scratch
// (openSaved / PersonalComputer still do that lazily).
func (s *Service) healPersonalHome(ctx context.Context, person identity.ID) {
	if person.IsZero() {
		return
	}
	home, _ := s.HomeSpace(ctx, person)
	saved := s.findDirect(ctx, directKey(person, person))
	if home == nil && saved == nil {
		return
	}
	if s.isPersonalHome(home, person) && (saved == nil || saved.ID == home.ID) {
		return
	}
	_, _, _, _ = s.ensurePersonalHome(ctx, person)
}

// ensurePersonalHome makes the person's home and Aseman chat the same space:
// Direct self-chat (person:person), Home=true, named Aseman, with the lead.
// Idempotent; collapses a legacy non-direct home and a separate self-chat.
func (s *Service) ensurePersonalHome(ctx context.Context, person identity.ID) (*space.Space, *space.Room, bool, error) {
	if person.IsZero() {
		return nil, nil, false, errs.InvalidArgument("person required")
	}
	var acc account.Account
	if err := s.R.Get(ctx, "accounts", person, &acc); err == nil {
		if acc.IsBot() || acc.Kind != account.KindUser || s.isBotAccount(ctx, person) {
			return nil, nil, false, errs.InvalidArgument("choose someone else to talk to")
		}
	} else if s.isBotAccount(ctx, person) {
		return nil, nil, false, errs.InvalidArgument("choose someone else to talk to")
	}

	s.homeMu.Lock()
	defer s.homeMu.Unlock()

	key := directKey(person, person)
	home, _ := s.HomeSpace(ctx, person)
	saved := s.findDirect(ctx, key)
	created := false

	switch {
	case s.isPersonalHome(home, person):
		// Already unified.
	case saved != nil && (home == nil || home.ID == saved.ID):
		if err := s.markPersonalHome(ctx, saved); err != nil {
			return nil, nil, false, err
		}
		home = saved
	case home != nil && saved == nil:
		if err := s.convertHomeToAseman(ctx, home, key); err != nil {
			return nil, nil, false, err
		}
	case home != nil && saved != nil && home.ID != saved.ID:
		// Prefer the self-chat (notes / assistant thread); retire the legacy project home.
		if err := s.markPersonalHome(ctx, saved); err != nil {
			return nil, nil, false, err
		}
		s.retireLegacyHome(ctx, home)
		home = saved
	default:
		sp, err := s.createSpace(ctx, person, "Aseman", "Your personal Aseman", key)
		if err != nil {
			return nil, nil, false, err
		}
		if err := s.markPersonalHome(ctx, sp); err != nil {
			return nil, nil, false, err
		}
		home = sp
		created = true
	}

	s.ensureAseman(ctx, home.ID)
	room, err := s.generalRoom(ctx, home.ID)
	if err != nil {
		return nil, nil, false, err
	}
	return home, room, created, nil
}

func (s *Service) markPersonalHome(ctx context.Context, sp *space.Space) error {
	if sp == nil {
		return errs.InvalidArgument("space required")
	}
	changed := false
	if !sp.Home {
		sp.Home = true
		changed = true
	}
	if !sp.Direct || sp.DirectKey == "" {
		sp.Direct = true
		sp.DirectKey = directKey(sp.OwnerID, sp.OwnerID)
		changed = true
	}
	if sp.Name != "Aseman" && (sp.Name == "Home" || sp.Name == "Saved Messages" || strings.HasSuffix(sp.Name, "'s Home") || sp.Name == "") {
		sp.Name = "Aseman"
		sp.Description = "Your personal Aseman"
		changed = true
	}
	if !changed {
		return nil
	}
	sp.UpdatedAt = time.Now().UTC()
	return s.R.Update(ctx, "spaces", sp.ID, sp)
}

func (s *Service) convertHomeToAseman(ctx context.Context, home *space.Space, key string) error {
	home.Direct = true
	home.DirectKey = key
	home.Home = true
	if home.Name == "Home" || strings.HasSuffix(home.Name, "'s Home") || home.Name == "Saved Messages" || home.Name == "" {
		home.Name = "Aseman"
		home.Description = "Your personal Aseman"
	}
	home.UpdatedAt = time.Now().UTC()
	return s.R.Update(ctx, "spaces", home.ID, home)
}

// retireLegacyHome clears the Home flag on a leftover non-direct project and
// deletes it when it looks like the old auto-created "{handle}'s Home".
func (s *Service) retireLegacyHome(ctx context.Context, old *space.Space) {
	if old == nil || old.Direct {
		return
	}
	old.Home = false
	old.UpdatedAt = time.Now().UTC()
	_ = s.R.Update(ctx, "spaces", old.ID, old)
	legacy := old.Name == "Home" || strings.HasSuffix(old.Name, "'s Home")
	if !legacy {
		return
	}
	_ = s.SandboxDestroy(ctx, old.ID)
	s.revokeSpaceInvitations(ctx, old.ID)
	s.deleteSpaceRoutines(ctx, old.ID)
	s.deleteSpaceFiles(ctx, old.ID)
	_ = s.R.Delete(ctx, "spaces", old.ID)
}

// Invite creates a pending invitation.
func (s *Service) Invite(ctx context.Context, inviter, spaceID, roomID, invitee identity.ID, role membership.Role) (*invitation.Invitation, error) {
	// A person chooses who may invite them (and a block always wins): the users
	// service holds those choices. Without it there are none to honour.
	if s.K != nil {
		if err := bridge.Invoke(ctx, s.K, "users", "AllowsInvite", []any{ctx, inviter, invitee}); err != nil && errs.CodeOf(err) == errs.CodePermission {
			return nil, err
		}
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	inv := &invitation.Invitation{
		Entity:  entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		SpaceID: spaceID, RoomID: roomID, InviterID: inviter, InviteeID: invitee,
		Role: role, Status: invitation.StatusPending,
	}
	if err := s.R.CreateID(ctx, "invitations", id, inv); err != nil {
		return nil, err
	}
	s.notifyInvite(inv)
	return inv, nil
}

// AcceptInvitation adds the invitee to the space (+room) as a member.
func (s *Service) AcceptInvitation(ctx context.Context, invitee identity.ID, invID identity.ID) error {
	inv := &invitation.Invitation{}
	if err := s.R.Get(ctx, "invitations", invID, inv); err != nil {
		return err
	}
	if inv.Status != invitation.StatusPending {
		return errs.Conflict("invitation not pending")
	}
	if inv.InviteeID != invitee {
		return errs.Permission("invitation is not for you")
	}
	now := time.Now().UTC()
	memID, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	mem := &membership.Membership{
		Entity:  entity.Entity{ID: memID, CreatedAt: now, UpdatedAt: now},
		SpaceID: inv.SpaceID, RoomID: inv.RoomID, MemberID: invitee, Role: inv.Role, JoinedAt: now,
	}
	if err := s.R.CreateID(ctx, "memberships", memID, mem); err != nil {
		return err
	}
	inv.Status = invitation.StatusAccepted
	inv.UpdatedAt = now
	if err := s.R.Update(ctx, "invitations", invID, inv); err != nil {
		return err
	}
	return nil
}

// AddBot adds a bot account to a space and the given room.
func (s *Service) AddBot(ctx context.Context, actor, spaceID, roomID, botID identity.ID) error {
	// A bot is a member by its account, whichever of its ids was given (the
	// app knows bots by their record id): every access check looks it up by
	// account.
	botID = s.botAccountOf(ctx, botID)
	s.botMembershipMu.Lock()
	defer s.botMembershipMu.Unlock()
	if err := s.Can(ctx, spaceID, roomID, actor, permission.SpaceManageBots); err != nil {
		return err
	}
	if !roomID.IsZero() {
		var room space.Room
		if err := s.R.Get(ctx, "rooms", roomID, &room); err != nil {
			return err
		}
		if room.SpaceID != spaceID {
			return errs.Permission("room belongs to another space")
		}
	}
	var memberships []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{Equal: map[string]any{"space_id": spaceID.String(), "member_id": botID.String(), "role": string(membership.RoleBot)}}, &memberships); err != nil {
		return err
	}
	for _, existing := range memberships {
		if existing.RoomID.IsZero() || existing.RoomID == roomID {
			return nil
		}
	}
	now := time.Now().UTC()
	memID, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	mem := &membership.Membership{
		Entity:  entity.Entity{ID: memID, CreatedAt: now, UpdatedAt: now},
		SpaceID: spaceID, RoomID: roomID, MemberID: botID, Role: membership.RoleBot, JoinedAt: now,
	}
	return s.R.CreateID(ctx, "memberships", memID, mem)
}

// RemoveBot removes a bot account's membership(s) from a space.
func (s *Service) RemoveBot(ctx context.Context, actor, spaceID, botAccountID identity.ID) error {
	botAccountID = s.botAccountOf(ctx, botAccountID)
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "member_id": botAccountID.String(), "role": string(membership.RoleBot)},
	}, &mems); err != nil {
		return err
	}
	for i := range mems {
		if err := s.R.Delete(ctx, "memberships", mems[i].ID); err != nil {
			return err
		}
	}
	return nil
}

// botAccountOf resolves a bot's record id or account id to its account id;
// an id that is neither is returned as given.
func (s *Service) botAccountOf(ctx context.Context, id identity.ID) identity.ID {
	if rec, err := s.botForMember(ctx, id); err == nil && rec != nil && !rec.AccountID.IsZero() {
		return rec.AccountID
	}
	return id
}

// MemberOf reports whether an account is a member of a space.
func (s *Service) MemberOf(ctx context.Context, spaceID, member identity.ID) (bool, error) {
	_, err := s.SpaceMembership(ctx, spaceID, member)
	if err != nil {
		return false, nil
	}
	return true, nil
}

// ListInvitations lists pending invitations for an account.
func (s *Service) ListInvitations(ctx context.Context, invitee identity.ID) ([]invitation.Invitation, error) {
	var out []invitation.Invitation
	if err := s.R.List(ctx, "invitations", database.Filter{
		Equal: map[string]any{"invitee_id": invitee.String(), "status": string(invitation.StatusPending)},
	}, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// deleteSpaceRoutines removes a workspace's routines, so nothing keeps firing
// (and notifying people) for a project that no longer exists.
func (s *Service) deleteSpaceRoutines(ctx context.Context, spaceID identity.ID) {
	var routines []struct {
		ID identity.ID `db:"id"`
	}
	if err := s.R.List(ctx, "routines", database.Filter{Equal: map[string]any{"space_id": spaceID.String()}}, &routines); err != nil {
		return
	}
	for _, r := range routines {
		_ = s.R.Delete(ctx, "routines", r.ID)
	}
}

// revokeSpaceInvitations revokes a workspace's pending invitations, so nobody
// is left holding an invitation to a workspace that no longer exists.
func (s *Service) revokeSpaceInvitations(ctx context.Context, spaceID identity.ID) {
	var pending []invitation.Invitation
	if err := s.R.List(ctx, "invitations", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "status": string(invitation.StatusPending)},
	}, &pending); err != nil {
		return
	}
	now := time.Now().UTC()
	for i := range pending {
		inv := pending[i]
		inv.Status = invitation.StatusRevoked
		inv.UpdatedAt = now
		_ = s.R.Update(ctx, "invitations", inv.ID, &inv)
	}
}
