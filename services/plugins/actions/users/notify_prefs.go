package users

import (
	"context"
	"encoding/json"
	"slices"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// What a person wants to be notified about. Every push goes through Push, so
// that is where it is decided (wantsPush): a person who muted a room is not
// sent its notifications at all, not just not shown them.
//
// Kinds a person can turn off, each covering the notifications of one thing:
//
//	rooms    messages in rooms (kind "message")
//	chats    personal chat messages (kind "dm")
//	calls    incoming-call alerts (kind "call")
//	invites  room invitations (kind "invite")
//
// A muted room or chat is quiet for its messages only; unread counts and
// the in-app incoming call are unaffected.

// notifyCategories are the kinds, in the order the app lists them.
var notifyCategories = []string{"rooms", "chats", "calls", "invites"}

// maxMuted bounds how many rooms and chats one person may mute.
const maxMuted = 1000

// notifyPrefs is one person's choices.
type notifyPrefs struct {
	ID          string    `db:"id" json:"id"`
	Disabled    string    `db:"disabled" json:"-"`     // JSON list of categories turned off
	MutedSpaces string    `db:"muted_spaces" json:"-"` // JSON list of room ids
	MutedPeers  string    `db:"muted_peers" json:"-"`  // JSON list of chat peers' account ids
	UpdatedAt   time.Time `db:"updated_at" json:"-"`
}

func listOf(raw string) []string {
	var out []string
	if raw != "" {
		_ = json.Unmarshal([]byte(raw), &out)
	}
	return out
}

func listJSON(list []string) string {
	if len(list) == 0 {
		return ""
	}
	raw, _ := json.Marshal(list)
	return string(raw)
}

// categoryOf is the kind of notification a push belongs to ("" for one that cannot be turned off).
func categoryOf(kind string) string {
	switch kind {
	case "message":
		return "rooms"
	case "dm":
		return "chats"
	case "call":
		return "calls"
	case "invite":
		return "invites"
	}
	return ""
}

// prefsOf reads a person's choices (none made yet = everything on).
func (s *Service) prefsOf(ctx context.Context, account identity.ID) notifyPrefs {
	var p notifyPrefs
	if err := s.R.GetString(ctx, "notification_prefs", account.String(), &p); err != nil {
		return notifyPrefs{ID: account.String()}
	}
	return p
}

// wantsPush says whether `account` should be sent this notification.
func (s *Service) wantsPush(ctx context.Context, account identity.ID, note PushNote) bool {
	p := s.prefsOf(ctx, account)
	if cat := categoryOf(note.Kind); cat != "" && slices.Contains(listOf(p.Disabled), cat) {
		return false
	}
	switch note.Kind {
	case "message":
		if note.Space != "" && slices.Contains(listOf(p.MutedSpaces), note.Space) {
			return false
		}
	case "dm":
		if note.Peer != "" && slices.Contains(listOf(p.MutedPeers), note.Peer) {
			return false
		}
	}
	return true
}

// savePrefs stores a person's choices.
func (s *Service) savePrefs(ctx context.Context, p notifyPrefs) error {
	p.UpdatedAt = time.Now().UTC()
	err := s.R.DB.Create(ctx, "notification_prefs", p.ID, &p)
	if errs.CodeOf(err) == errs.CodeAlreadyExists || errs.CodeOf(err) == errs.CodeConflict {
		err = s.R.DB.Update(ctx, "notification_prefs", p.ID, &p)
	}
	return err
}

func notifyActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "users", Name: "notify_prefs", Summary: "What the caller is notified about, and what they muted", Handler: s.notifyGet},
		helper.Action{Namespace: "users", Name: "notify_set", Summary: "Turn a kind of notification on or off", Handler: s.notifySet},
		helper.Action{Namespace: "users", Name: "notify_mute", Summary: "Mute or unmute a room or a chat's notifications", Handler: s.notifyMute},
	}
}

func prefsView(p notifyPrefs) map[string]any {
	off := listOf(p.Disabled)
	cats := make(map[string]bool, len(notifyCategories))
	for _, c := range notifyCategories {
		cats[c] = !slices.Contains(off, c)
	}
	spaces, peers := listOf(p.MutedSpaces), listOf(p.MutedPeers)
	if spaces == nil {
		spaces = []string{}
	}
	if peers == nil {
		peers = []string{}
	}
	return map[string]any{"categories": cats, "muted_spaces": spaces, "muted_peers": peers}
}

func (s *Service) notifyGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	return helper.JSON(prefsView(s.prefsOf(ctx, req.Caller.ID)))
}

func (s *Service) notifySet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Category string `json:"category"`
		Enabled  bool   `json:"enabled"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if !slices.Contains(notifyCategories, in.Category) {
		return nil, errs.InvalidArgument("category must be rooms, chats, calls or invites")
	}
	p := s.prefsOf(ctx, req.Caller.ID)
	off := slices.DeleteFunc(listOf(p.Disabled), func(c string) bool { return c == in.Category })
	if !in.Enabled {
		off = append(off, in.Category)
	}
	p.Disabled = listJSON(off)
	if err := s.savePrefs(ctx, p); err != nil {
		return nil, err
	}
	return helper.JSON(prefsView(p))
}

func (s *Service) notifyMute(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Kind  string `json:"kind"` // "space" (a room) or "peer" (a personal chat)
		ID    string `json:"id"`
		Muted bool   `json:"muted"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.ID)
	if err != nil {
		return nil, err
	}
	p := s.prefsOf(ctx, req.Caller.ID)
	var list *string
	switch in.Kind {
	case "space":
		list = &p.MutedSpaces
	case "peer":
		list = &p.MutedPeers
	default:
		return nil, errs.InvalidArgument("kind must be space or peer")
	}
	next := slices.DeleteFunc(listOf(*list), func(x string) bool { return x == id.String() })
	if in.Muted {
		if len(next) >= maxMuted {
			return nil, errs.InvalidArgument("too many muted; unmute some first")
		}
		next = append(next, id.String())
	}
	*list = listJSON(next)
	if err := s.savePrefs(ctx, p); err != nil {
		return nil, err
	}
	return helper.JSON(prefsView(p))
}
