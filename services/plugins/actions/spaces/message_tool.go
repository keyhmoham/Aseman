package spaces

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// messageTool implements the message_send tool: aseman (the orchestrator) —
// or any agent in the workspace — posts a message into a room's chat at any
// time. It is the channel that lets aseman send multiple messages, status
// updates or follow-ups on its own initiative, not only in reply to a mention.
func (s *Service) messageTool(ctx context.Context, spaceID identity.ID, argsJSON string) (string, error) {
	var in struct {
		Input string `json:"input"`
		Room  string `json:"room"`
		Body  string `json:"body"`
		To    string `json:"to"`
	}
	_ = json.Unmarshal([]byte(argsJSON), &in)
	// Fallback: parse "input" as key=value pairs (agent tool calls).
	if in.Input != "" && in.Body == "" {
		for _, pair := range strings.Split(in.Input, "&") {
			if i := strings.IndexByte(pair, '='); i >= 0 {
				k, v := strings.TrimSpace(pair[:i]), strings.TrimSpace(pair[i+1:])
				switch k {
				case "room":
					in.Room = v
				case "body", "message", "text":
					in.Body = v
				case "to":
					in.To = v
				}
			}
		}
	}
	body := strings.TrimSpace(in.Body)
	if body == "" {
		return "", errs.InvalidArgument("message_send requires a body (the message text)")
	}
	sender, err := s.AsemanAccount(ctx)
	if err != nil {
		return "", errs.New(errs.CodeUnavailable, "aseman orchestrator not available")
	}
	if in.To != "" {
		to, perr := identity.Parse(in.To)
		if perr != nil {
			return "", errs.InvalidArgument("invalid recipient id")
		}
		if err := s.postPeerMessage(ctx, sender, to, body); err != nil {
			return "", err
		}
		return fmt.Sprintf("message sent to %s", to.String()), nil
	}
	var roomID identity.ID
	if in.Room != "" {
		r, perr := identity.Parse(in.Room)
		if perr != nil {
			return "", errs.InvalidArgument("invalid room id")
		}
		roomID = r
	} else if r := vmm.RoomFrom(ctx); r != "" {
		// Default to the room the request is running in (where the chat is), so
		// a message the agent posts lands in the right room, not general.
		rid, perr := identity.Parse(r)
		if perr != nil {
			return "", errs.InvalidArgument("invalid room from context")
		}
		roomID = rid
	}
	if err := helper.CheckContextAccess(ctx, s.R, spaceID, roomID, true); err != nil {
		return "", err
	}
	if err := s.postMessage(ctx, spaceID, roomID, sender, body, message.KindMessage); err != nil {
		return "", err
	}
	return "message posted to the room", nil
}

// postPeerMessage delivers a fire-and-forget message packet to a specific user
// or bot account (the message namespace's async channel), so aseman can also
// reach individuals, not only rooms.
func (s *Service) postPeerMessage(ctx context.Context, from, to identity.ID, body string) error {
	if s.Msg == nil {
		return errs.New(errs.CodeUnavailable, "message service not wired")
	}
	_, err := s.Msg.SendPacket(ctx, from, to, body, "")
	return err
}
