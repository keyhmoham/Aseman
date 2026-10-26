package spaces

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/spaces/models/membership"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/usage/models"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// MentionReply is a reply produced by an agent that a room message triggered.
// Reply and MessageID are empty when the agent answered only through tools (it
// is still listed so its usage is billed).
type MentionReply struct {
	BotID     string `json:"bot_id"`
	BotHandle string `json:"bot_handle,omitempty"`
	MessageID string `json:"message_id"`
	Reply     string `json:"reply"`
}

// deliverMentionsAsync runs mention delivery in the background so a room
// message returns immediately. Agent replies are stored as their own chat
// messages inside DeliverMentions, and each agent turn bills itself there.
func (s *Service) deliverMentionsAsync(ctx context.Context, spaceID, roomID identity.ID, msg *message.Message, caller identity.ID) {
	// Agents brought in by an agent work on its run and stop with it. They
	// join before the delivery goes off on its own, so the run's turn cannot
	// end first.
	ctx, done := s.joinRun(ctx)
	if ctx.Err() != nil {
		done()
		return
	}
	go func() {
		defer done()
		s.deliverMentions(ctx, spaceID, roomID, msg)
	}()
}

func (s *Service) deliverMentions(ctx context.Context, spaceID, roomID identity.ID, msg *message.Message) {
	if _, err := s.DeliverMentions(ctx, spaceID, roomID, msg); err != nil {
		s.L.Warn("mention delivery failed", "space", spaceID.String(), "err", err)
	}
}

// DeliverMentions routes a room message to the space's agents. Mentioned agents
// are triggered — all of them at once, each on its own turn — and their replies
// are stored back into the room as answers to the message (reply_to). An agent
// waiting on a question in the room receives the message as its answer. Every
// other agent observes the message so its next turn knows what was said.
func (s *Service) DeliverMentions(ctx context.Context, spaceID, roomID identity.ID, msg *message.Message) ([]MentionReply, error) {
	// Publish the agents' live status to this room while they work; cleared
	// when delivery finishes so the chat's working indicator disappears.
	ctx, done := s.activityWriter(ctx, roomID)
	defer done()
	// Tool posts during this delivery (file_send, image_generate, ...) default
	// to the room the message was posted in, not the space's general room.
	ctx = vmm.WithRoom(ctx, roomID.String())
	var mems []membership.Membership
	if err := s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String(), "role": string(membership.RoleBot)},
	}, &mems); err != nil {
		return nil, err
	}
	mentions := msg.ParseMentions()
	atts, err := s.ResolveAttachments(ctx, msg.SenderID, msg.ParseAttachments())
	if err != nil {
		atts = nil
	}
	// One request id correlates every agent that answers this room message.
	if usage.RequestIDFrom(ctx) == "" {
		if id, ierr := identity.New(s.K.NodeID()); ierr == nil {
			ctx = usage.WithRequestID(ctx, id.String())
		}
	}
	var (
		mu         sync.Mutex
		wg         sync.WaitGroup
		replies    []MentionReply
		failure    error
		failureFor bool
	)
	delivered := map[string]bool{}
	for i := range mems {
		member := mems[i]
		if (!member.RoomID.IsZero() && member.RoomID != roomID) || delivered[member.MemberID.String()] {
			continue
		}
		delivered[member.MemberID.String()] = true
		rec, err := s.botForMember(ctx, member.MemberID)
		if err != nil || !isAgentRuntime(rec) || rec.AccountID == msg.SenderID {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			reply, err := s.deliverToAgent(ctx, spaceID, roomID, msg, rec, mentions, atts)
			mu.Lock()
			defer mu.Unlock()
			// A mentioned agent's failure is the one the sender asked about, so
			// it is never masked by a bystander's.
			mentioned := isMentioned(rec, mentions)
			if err != nil && (failure == nil || !failureFor && mentioned) {
				failure, failureFor = err, mentioned
			}
			if reply != nil {
				replies = append(replies, *reply)
			}
		}()
	}
	wg.Wait()
	return replies, failure
}

// mentionsAgent reports whether any of the given bot identifiers (bot id,
// account id, vm id, or name) appear in a message's mention list.
func mentionsAgent(mentions []string, ids ...string) bool {
	for _, m := range mentions {
		for _, id := range ids {
			if id != "" && strings.EqualFold(strings.TrimPrefix(m, "@"), id) {
				return true
			}
		}
	}
	return false
}

// withoutToolMessages drops KindTool rows from a chat feed. Those are microtool
// replies (microtool/page API traffic, …) and must not appear as conversation.
func withoutToolMessages(msgs []message.Message) []message.Message {
	out := msgs[:0]
	for _, m := range msgs {
		if m.Kind == message.KindTool {
			continue
		}
		out = append(out, m)
	}
	return out
}

// PostMessage posts a normal conversation message from the given sender into a
// room (rendered as a chat message, not a log).
func (s *Service) PostMessage(ctx context.Context, spaceID, roomID, sender identity.ID, body string) error {
	return s.postMessage(ctx, spaceID, roomID, sender, body, message.KindMessage)
}

// PostRoomMessage writes an agent work-log entry into a room (KindLog): the
// chat shows these as the agent's working steps, live and then as history.
func (s *Service) PostRoomMessage(ctx context.Context, spaceID, roomID, sender identity.ID, body string) error {
	return s.postMessage(ctx, spaceID, roomID, sender, body, message.KindLog)
}

// postMessage writes a room message with an explicit kind, resolving the
// general room when roomID is zero.
func (s *Service) postMessage(ctx context.Context, spaceID, roomID, sender identity.ID, body, kind string) error {
	if body == "" {
		return errs.InvalidArgument("message body required")
	}
	if roomID.IsZero() {
		room, err := s.generalRoom(ctx, spaceID)
		if err != nil {
			return err
		}
		roomID = room.ID
	}
	_, err := s.storeRoomMessage(ctx, spaceID, roomID, sender, body, kind, "")
	return err
}

// generalRoom resolves the first room created in a space (the general room).
func (s *Service) generalRoom(ctx context.Context, spaceID identity.ID) (*space.Room, error) {
	var rooms []space.Room
	if err := s.R.List(ctx, "rooms", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String()}, OrderBy: "created_at", Asc: true, Limit: 1,
	}, &rooms); err != nil {
		return nil, err
	}
	if len(rooms) == 0 {
		return nil, errs.New(errs.CodeNotFound, "no room in space")
	}
	return &rooms[0], nil
}

// storeBotReply persists an agent's reply as a room message from the bot's
// account, as an answer to the message that triggered it.
func (s *Service) storeBotReply(ctx context.Context, spaceID, roomID, sender identity.ID, body, replyTo string) (identity.ID, error) {
	return s.storeRoomMessage(ctx, spaceID, roomID, sender, body, message.KindMessage, replyTo)
}

// storeRoomMessage persists a room message from the given sender with an
// explicit kind (message or log), optionally answering another message.
func (s *Service) storeRoomMessage(ctx context.Context, spaceID, roomID, sender identity.ID, body, kind, replyTo string) (identity.ID, error) {
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return identity.ID{}, err
	}
	now := time.Now().UTC()
	m := &message.Message{
		Entity:  entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		SpaceID: spaceID, RoomID: roomID, SenderID: sender, Body: body, Kind: kind, ReplyTo: replyTo,
	}
	m.SetMentions(nil)
	if err := s.R.CreateID(ctx, "messages", id, m); err != nil {
		return identity.ID{}, errs.Wrap(errs.CodeInternal, err, "store room message")
	}
	s.notifyRoomMessage(m)
	return id, nil
}

func identityActor(value string, fallback identity.ID) identity.ID {
	id, err := identity.Parse(value)
	if err != nil {
		return fallback
	}
	return id
}

// payer is who pays for work an account starts. People pay for themselves; an
// agent acting inside a run spends on behalf of the person who started that run
// (the execution actor), so a swarm never bills its own agents' wallets.
func (s *Service) payer(ctx context.Context, caller identity.ID) identity.ID {
	actor := vmm.ExecutionFrom(ctx).ActorID
	if actor == "" || actor == caller.String() {
		return caller
	}
	if s.isBotAccount(ctx, caller) {
		return identityActor(actor, caller)
	}
	return caller
}

// isBotAccount reports whether an account belongs to a bot.
func (s *Service) isBotAccount(ctx context.Context, id identity.ID) bool {
	_, err := s.botForMember(ctx, id)
	return err == nil
}

// isMentioned reports whether a message's mentions address rec (by bot or
// account id).
func isMentioned(rec *bot.Bot, mentions []string) bool {
	return mentionsAgent(mentions, rec.ID.String(), rec.AccountID.String(), rec.VMID, rec.Name)
}

// actingAs binds the person a delivery acts for: the execution actor when an
// agent's message triggered it, else the message's sender.
func actingAs(ctx context.Context, sender identity.ID) (context.Context, identity.ID) {
	policy := vmm.ExecutionFrom(ctx)
	if policy.ActorID != "" {
		return ctx, identityActor(policy.ActorID, sender)
	}
	return helper.WithActor(ctx, sender), sender
}
