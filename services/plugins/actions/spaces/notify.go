package spaces

import (
	"context"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/spaces/models/invitation"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Telling people on their phones what happened in a project while they were
// not looking: a message from someone else, an agent's reply, an invitation.
// The users namespace owns the devices and the sending (users.Push); this
// decides who is told and what the notification says.

// notifyDelay is how long a message waits before it is announced. Long enough
// for the app the person has open to mark it read (then nothing is sent), and
// for an agent's burst of messages to settle into one notification.
var notifyDelay = 4 * time.Second

// pendingNotice counts the messages of each project still waiting to be
// announced: only the newest of a burst is.
var pendingNotice = struct {
	sync.Mutex
	latest map[string]string
}{latest: map[string]string{}}

// notifyRoomMessage announces a conversation message to the project's people,
// except its sender and anyone who has read it by the time it would go out.
// Work logs and tool replies are not conversation and are not announced.
func (s *Service) notifyRoomMessage(msg *message.Message) {
	if msg == nil || s.K == nil || (msg.Kind != "" && msg.Kind != message.KindMessage) {
		return
	}
	space, id := msg.SpaceID.String(), msg.ID.String()
	pendingNotice.Lock()
	pendingNotice.latest[space] = id
	pendingNotice.Unlock()
	copied := *msg
	go func() {
		time.Sleep(notifyDelay)
		pendingNotice.Lock()
		newest := pendingNotice.latest[space] == id
		if newest {
			delete(pendingNotice.latest, space)
		}
		pendingNotice.Unlock()
		if !newest {
			return // a later message of the same burst speaks for this one
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		s.announceMessage(ctx, &copied)
	}()
}

func (s *Service) announceMessage(ctx context.Context, msg *message.Message) {
	if _, err := s.GetSpace(ctx, msg.SpaceID); errs.CodeOf(err) == errs.CodeNotFound {
		return // the project was deleted: nothing to announce
	}
	var to []identity.ID
	for _, person := range s.peopleOf(ctx, msg.SpaceID) {
		if person == msg.SenderID {
			continue
		}
		// Read already, on any device: nothing to announce.
		if !s.SeenAt(ctx, person, msg.SpaceID).Before(msg.CreatedAt) {
			continue
		}
		to = append(to, person)
	}
	if len(to) == 0 {
		return
	}
	title := "Aseman"
	if sp, err := s.GetSpace(ctx, msg.SpaceID); err == nil && strings.TrimSpace(sp.Name) != "" {
		title = sp.Name
	}
	sender, _ := s.participants().get(ctx, msg.SenderID)["display_name"].(string)
	s.push(ctx, to, map[string]any{
		"title": title, "body": noticeBody(sender, msg.Body, len(msg.ParseAttachments())),
		"kind": "message", "space": msg.SpaceID.String(), "room": msg.RoomID.String(),
		// The next message of this project replaces this notification rather than stacking under it.
		"collapse": "m" + msg.SpaceID.String(),
	})
}

// notifyInvite tells someone they were invited to a project.
func (s *Service) notifyInvite(inv *invitation.Invitation) {
	if inv == nil || s.K == nil {
		return
	}
	copied := *inv
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		project := "a room"
		if sp, err := s.GetSpace(ctx, copied.SpaceID); err == nil && strings.TrimSpace(sp.Name) != "" {
			project = sp.Name
		}
		inviter, _ := s.participants().get(ctx, copied.InviterID)["display_name"].(string)
		if inviter == "" {
			inviter = "Someone"
		}
		s.push(ctx, []identity.ID{copied.InviteeID}, map[string]any{
			"title": "Room invitation", "body": inviter + " invited you to " + project + ".",
			"kind": "invite", "space": copied.SpaceID.String(),
		})
	}()
}

// push hands a notification to the users namespace. A failure here is only
// logged: what it announces has already happened and been stored.
func (s *Service) push(ctx context.Context, to []identity.ID, note map[string]any) {
	if s.K == nil {
		return
	}
	if err := bridge.Invoke(ctx, s.K, "users", "Push", []any{ctx, to, note}); err != nil && s.L != nil {
		s.L.Warn("notification not sent", "error", err)
	}
}

// peopleOf lists the people (not agents or tools) who belong to a project.
func (s *Service) peopleOf(ctx context.Context, spaceID identity.ID) []identity.ID {
	var members []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{Equal: map[string]any{"space_id": spaceID.String()}}, &members); err != nil {
		return nil
	}
	seen := map[identity.ID]bool{}
	var out []identity.ID
	for _, m := range members {
		if seen[m.MemberID] {
			continue
		}
		seen[m.MemberID] = true
		var acc account.Account
		if s.R.Get(ctx, "accounts", m.MemberID, &acc) == nil && acc.Kind == account.KindUser {
			out = append(out, m.MemberID)
		}
	}
	return out
}

var (
	noticeLinks  = regexp.MustCompile(`!?\[([^\]]*)\]\([^)]*\)`)
	noticeMarks  = regexp.MustCompile("[*_`#>~]+")
	noticeSpaces = regexp.MustCompile(`\s+`)
)

// noticeBody is a message as one line of a notification: who said it and the
// start of what they said, without the markup it was written in.
func noticeBody(sender, body string, attachments int) string {
	text := noticeLinks.ReplaceAllString(body, "$1")
	text = noticeMarks.ReplaceAllString(text, "")
	text = strings.TrimSpace(noticeSpaces.ReplaceAllString(text, " "))
	if text == "" {
		switch {
		case attachments == 1:
			text = "Sent a file"
		case attachments > 1:
			text = "Sent files"
		default:
			text = "Sent a message"
		}
	}
	if runes := []rune(text); len(runes) > 160 {
		text = strings.TrimSpace(string(runes[:159])) + "…"
	}
	if sender = strings.TrimSpace(sender); sender != "" {
		return sender + ": " + text
	}
	return text
}
