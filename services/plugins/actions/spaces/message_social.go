package spaces

import (
	"context"
	"strings"
	"time"
	"unicode"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	"github.com/aseman/aseman/plugins/actions/spaces/models/permission"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Room-message social actions (react / hide-for-me / keep files). These use
// the room message id — the same id the messenger already has — so they work
// in project rooms and in direct / Saved Messages chats alike.

const maxReactionRunes = 16

type messageReaction struct {
	ID        string    `db:"id" json:"-"`
	MessageID string    `db:"message_id" json:"-"`
	UserID    string    `db:"user_id" json:"user_id"`
	Emoji     string    `db:"emoji" json:"emoji"`
	CreatedAt time.Time `db:"created_at" json:"-"`
}

type messageHidden struct {
	ID        string    `db:"id" json:"-"`
	UserID    string    `db:"user_id" json:"-"`
	MessageID string    `db:"message_id" json:"-"`
	CreatedAt time.Time `db:"created_at" json:"-"`
}

type keptRoomFile struct {
	ID        string    `db:"id" json:"-"`
	OwnerID   string    `db:"owner_id" json:"-"`
	FromID    string    `db:"from_id" json:"-"`
	SourceID  string    `db:"source_id" json:"-"`
	MessageID string    `db:"message_id" json:"-"`
	Name      string    `db:"name" json:"-"`
	Mime      string    `db:"mime" json:"-"`
	Size      int64     `db:"size" json:"-"`
	CreatedAt time.Time `db:"created_at" json:"-"`
}

func messageSocialActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "spaces", Name: "message_react", Summary: "React to a room message with an emoji (empty emoji removes yours)", Handler: s.messageReact},
		helper.Action{Namespace: "spaces", Name: "message_hide", Summary: "Hide a room message for yourself only", Handler: s.messageHide},
		helper.Action{Namespace: "spaces", Name: "message_keep", Summary: "Keep files of a room message in your own storage", Handler: s.messageKeep},
	}
}

func validRoomEmoji(e string) bool {
	n := 0
	for _, r := range e {
		n++
		if unicode.IsLetter(r) || unicode.IsSpace(r) {
			return false
		}
	}
	return n > 0 && n <= maxReactionRunes
}

func (s *Service) loadRoomMessage(ctx context.Context, spaceID, msgID identity.ID) (*message.Message, error) {
	msg := &message.Message{}
	if err := s.R.Get(ctx, "messages", msgID, msg); err != nil {
		return nil, errs.NotFound("message not found")
	}
	if !spaceID.IsZero() && msg.SpaceID != spaceID {
		return nil, errs.NotFound("message not found")
	}
	return msg, nil
}

func (s *Service) messageReact(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Space   string `json:"space"`
		Message string `json:"message"`
		Emoji   string `json:"emoji"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	msgID, err := identity.Parse(in.Message)
	if err != nil {
		return nil, errs.InvalidArgument("message")
	}
	msg, err := s.loadRoomMessage(ctx, spID, msgID)
	if err != nil {
		return nil, err
	}
	if err := s.Can(ctx, msg.SpaceID, msg.RoomID, req.Caller.ID, permission.RoomRead); err != nil {
		return nil, err
	}
	emoji := strings.TrimSpace(in.Emoji)
	key := msgID.String() + ":" + req.Caller.ID.String()
	if emoji == "" {
		if err := s.R.DB.Delete(ctx, "message_reactions", key); err != nil && errs.CodeOf(err) != errs.CodeNotFound {
			return nil, err
		}
	} else {
		if !validRoomEmoji(emoji) {
			return nil, errs.InvalidArgument("emoji must be a single emoji")
		}
		row := &messageReaction{
			ID: key, MessageID: msgID.String(), UserID: req.Caller.ID.String(),
			Emoji: emoji, CreatedAt: time.Now().UTC(),
		}
		err := s.R.DB.Create(ctx, "message_reactions", key, row)
		if errs.CodeOf(err) == errs.CodeAlreadyExists || errs.CodeOf(err) == errs.CodeConflict {
			err = s.R.DB.Update(ctx, "message_reactions", key, row)
		}
		if err != nil {
			return nil, err
		}
	}
	return helper.JSON(map[string]any{"ok": true, "reactions": s.reactionsForMessages(ctx, []string{msgID.String()})[msgID.String()]})
}

func (s *Service) messageHide(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Space   string `json:"space"`
		Message string `json:"message"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	msgID, err := identity.Parse(in.Message)
	if err != nil {
		return nil, errs.InvalidArgument("message")
	}
	msg, err := s.loadRoomMessage(ctx, spID, msgID)
	if err != nil {
		return nil, err
	}
	if err := s.Can(ctx, msg.SpaceID, msg.RoomID, req.Caller.ID, permission.RoomRead); err != nil {
		return nil, err
	}
	row := &messageHidden{
		ID: req.Caller.ID.String() + ":" + msgID.String(),
		UserID: req.Caller.ID.String(), MessageID: msgID.String(),
		CreatedAt: time.Now().UTC(),
	}
	if err := s.R.DB.Create(ctx, "message_hidden", row.ID, row); err != nil &&
		errs.CodeOf(err) != errs.CodeAlreadyExists && errs.CodeOf(err) != errs.CodeConflict {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

func (s *Service) messageKeep(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Space   string `json:"space"`
		Message string `json:"message"`
		File    string `json:"file"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	msgID, err := identity.Parse(in.Message)
	if err != nil {
		return nil, errs.InvalidArgument("message")
	}
	msg, err := s.loadRoomMessage(ctx, spID, msgID)
	if err != nil {
		return nil, err
	}
	if err := s.Can(ctx, msg.SpaceID, msg.RoomID, req.Caller.ID, permission.RoomRead); err != nil {
		return nil, err
	}
	me := req.Caller.ID
	if msg.SenderID == me {
		return nil, errs.InvalidArgument("only a file someone else sent can be kept")
	}
	ids := msg.ParseAttachments()
	if in.File != "" {
		found := false
		for _, id := range ids {
			found = found || id == in.File
		}
		if !found {
			return nil, errs.InvalidArgument("that file is not in this message")
		}
		ids = []string{in.File}
	}
	if len(ids) == 0 {
		return nil, errs.InvalidArgument("this message has no files")
	}
	kept := map[string]string{}
	for _, id := range ids {
		if isFolderRef(id) {
			continue
		}
		fid, err := identity.Parse(id)
		if err != nil {
			continue
		}
		var src filedata.File
		if err := s.R.Get(ctx, "files", fid, &src); err != nil {
			return nil, errs.Conflict("a file is no longer available")
		}
		if err := s.CanReadFile(ctx, fid, me); err != nil {
			return nil, err
		}
		// Already kept?
		var existing []keptRoomFile
		_ = s.R.List(ctx, "kept_room_files", database.Filter{
			Equal: map[string]any{"owner_id": me.String(), "source_id": id}, Limit: 1,
		}, &existing)
		if len(existing) > 0 {
			kept[id] = existing[0].ID
			continue
		}
		own, err := identity.New(s.K.NodeID())
		if err != nil {
			return nil, err
		}
		now := time.Now().UTC()
		copyOf := &filedata.File{
			Entity: entity.Entity{ID: own, CreatedAt: now, UpdatedAt: now},
			OwnerID: me, Name: src.Name, Mime: src.Mime, Size: src.Size, StorageKey: src.StorageKey,
		}
		if err := s.R.CreateID(ctx, "files", own, copyOf); err != nil {
			return nil, err
		}
		link := &keptRoomFile{
			ID: own.String(), OwnerID: me.String(), FromID: msg.SenderID.String(),
			SourceID: id, MessageID: msgID.String(), Name: src.Name, Mime: src.Mime,
			Size: src.Size, CreatedAt: now,
		}
		if err := s.R.DB.Create(ctx, "kept_room_files", link.ID, link); err != nil {
			_ = s.R.Delete(ctx, "files", own)
			return nil, err
		}
		kept[id] = own.String()
	}
	if len(kept) == 0 {
		return nil, errs.InvalidArgument("this message has no files that can be kept")
	}
	return helper.JSON(map[string]any{"ok": true, "kept": kept})
}

func (s *Service) reactionsForMessages(ctx context.Context, messageIDs []string) map[string][]map[string]any {
	out := map[string][]map[string]any{}
	if len(messageIDs) == 0 {
		return out
	}
	ids := make([]any, 0, len(messageIDs))
	for _, id := range messageIDs {
		if id != "" {
			ids = append(ids, id)
		}
	}
	if len(ids) == 0 {
		return out
	}
	var rows []messageReaction
	if err := s.R.List(ctx, "message_reactions", database.Filter{
		In: map[string][]any{"message_id": ids}, OrderBy: "created_at", Asc: true,
	}, &rows); err != nil {
		return out
	}
	for _, r := range rows {
		out[r.MessageID] = append(out[r.MessageID], map[string]any{
			"user_id": r.UserID, "emoji": r.Emoji,
		})
	}
	return out
}

func (s *Service) hiddenMessagesFor(ctx context.Context, user identity.ID) map[string]bool {
	out := map[string]bool{}
	if user.IsZero() {
		return out
	}
	var rows []messageHidden
	if err := s.R.List(ctx, "message_hidden", database.Filter{
		Equal: map[string]any{"user_id": user.String()},
	}, &rows); err != nil {
		return out
	}
	for _, r := range rows {
		out[r.MessageID] = true
	}
	return out
}
