package spaces

import (
	"context"
	"regexp"
	"strings"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
)

// A room can be made for something: its purpose, an icon and a colour. The
// lead greets it and offers three things to start on, agents working there are
// told what it is for, and the tasks started there wear its colour.

var (
	roomColor = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)
	roomIcon  = regexp.MustCompile(`^[a-z0-9_]{1,40}$`)
)

func validRoomLook(icon, color string) error {
	if color != "" && !roomColor.MatchString(color) {
		return errs.InvalidArgument("color is #rrggbb")
	}
	if icon != "" && !roomIcon.MatchString(icon) {
		return errs.InvalidArgument("icon is a name like rocket or shopping_cart")
	}
	return nil
}

func clipRoomText(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) > n {
		return s[:n]
	}
	return s
}

// greetRoom has the lead say hello in a new room made for something. Best
// effort: a room without its greeting is still a room.
func (s *Service) greetRoom(ctx context.Context, actor identity.ID, room *space.Room) {
	prompt := "This room was just made for: " + room.Purpose + ". Speak first: say hello in one line, then offer three specific things " +
		"you could start on here, as a short numbered list. End with <replies>first | second | third</replies> naming them in a few words each. Do not start any of them yet."
	if _, err := s.AskLead(ctx, actor, room.SpaceID, room.ID, "greet-"+room.ID.String(), "", prompt, true); err != nil && s.L != nil {
		s.L.Warn("room not greeted", "room", room.ID.String(), "error", err)
	}
}
