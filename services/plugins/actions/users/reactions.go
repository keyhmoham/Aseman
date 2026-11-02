package users

import (
	"context"
	"strings"
	"time"
	"unicode"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// maxEmojiRunes bounds one reaction: a single emoji can be several code points
// (skin tone, ZWJ family, flag), never a sentence.
const maxEmojiRunes = 16

// directReaction is one person's emoji on one message.
type directReaction struct {
	ID        string    `db:"id" json:"-"`
	MessageID string    `db:"message_id" json:"-"`
	UserID    string    `db:"user_id" json:"user_id"`
	Emoji     string    `db:"emoji" json:"emoji"`
	CreatedAt time.Time `db:"created_at" json:"-"`
}

// validEmoji is true for a short run of symbols: no letters, no spaces (a
// keycap such as 1\ufe0f\u20e3 carries a digit, which is allowed).
func validEmoji(e string) bool {
	n := 0
	for _, r := range e {
		n++
		if unicode.IsLetter(r) || unicode.IsSpace(r) {
			return false
		}
	}
	return n > 0 && n <= maxEmojiRunes
}

// directReactions are the reactions on msgs, by message id, oldest first.
func (s *Service) directReactions(ctx context.Context, msgs []message.Direct) map[string][]directReaction {
	out := map[string][]directReaction{}
	if len(msgs) == 0 {
		return out
	}
	ids := make([]any, len(msgs))
	for i := range msgs {
		ids[i] = msgs[i].ID.String()
	}
	var rows []directReaction
	if err := s.R.List(ctx, "direct_reactions", database.Filter{In: map[string][]any{"message_id": ids}, OrderBy: "created_at", Asc: true}, &rows); err != nil {
		return out // reactions are a garnish: the conversation still loads
	}
	for _, r := range rows {
		out[r.MessageID] = append(out[r.MessageID], r)
	}
	return out
}

// dmReact implements users.dm_react: put an emoji on a message of the caller's
// conversation, or take theirs off (empty emoji). One emoji per person.
type dmReact struct{ s *Service }

func (a *dmReact) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "dm_react", Summary: "React to a message with an emoji (empty emoji removes your reaction)"}
}

func (a *dmReact) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		ID    string `json:"id"`
		Emoji string `json:"emoji"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.ID)
	if err != nil {
		return nil, err
	}
	dm, err := a.s.getDirect(ctx, id)
	if err != nil {
		return nil, err
	}
	if dm.From != req.Caller.ID && dm.To != req.Caller.ID {
		return nil, errs.New(errs.CodePermission, "not your conversation")
	}
	if !dm.DeletedAt.IsZero() {
		return nil, errs.Conflict("this message was deleted")
	}
	emoji := strings.TrimSpace(in.Emoji)
	key := id.String() + ":" + req.Caller.ID.String()
	if emoji == "" {
		if err := a.s.R.DB.Delete(ctx, "direct_reactions", key); err != nil && errs.CodeOf(err) != errs.CodeNotFound {
			return nil, err
		}
	} else {
		if !validEmoji(emoji) {
			return nil, errs.InvalidArgument("emoji must be a single emoji")
		}
		row := &directReaction{ID: key, MessageID: id.String(), UserID: req.Caller.ID.String(), Emoji: emoji, CreatedAt: time.Now().UTC()}
		err := a.s.R.DB.Create(ctx, "direct_reactions", key, row)
		if errs.CodeOf(err) == errs.CodeAlreadyExists || errs.CodeOf(err) == errs.CodeConflict {
			err = a.s.R.DB.Update(ctx, "direct_reactions", key, row)
		}
		if err != nil {
			return nil, err
		}
	}
	rs := a.s.directReactions(ctx, []message.Direct{*dm})[id.String()]
	return helper.JSON(map[string]any{"ok": true, "reactions": rs})
}
