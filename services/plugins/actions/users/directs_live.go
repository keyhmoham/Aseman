package users

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// directView is a message as a client reads it: its text (empty once its
// sender took it back), what it replies to, and whether it was edited.
func directView(dm message.Direct) map[string]any {
	v := map[string]any{"id": dm.ID.String(), "from_id": dm.From.String(), "to_id": dm.To.String(), "body": dm.Body,
		"sent_at": dm.SentAt, "created_at": dm.CreatedAt}
	if dm.ReplyTo != "" {
		v["reply_to"] = dm.ReplyTo
	}
	if dm.AgentID != "" {
		v["agent_id"] = dm.AgentID
	}
	if dm.Brain != "" {
		v["brain"] = dm.Brain
	}
	// What a Aseman answer proposed to do, waiting for a yes (or what became of it).
	if p := proposalView(dm.Action); p != nil {
		v["proposal"] = p
	}
	if !dm.EditedAt.IsZero() {
		v["edited_at"] = dm.EditedAt
	}
	if !dm.DeletedAt.IsZero() {
		v["deleted"] = true
		v["body"] = ""
	}
	return v
}

// getDirect reads one message, decrypted.
func (s *Service) getDirect(ctx context.Context, id identity.ID) (*message.Direct, error) {
	var dm message.Direct
	if err := s.R.Get(ctx, "directs", id, &dm); err != nil {
		return nil, err
	}
	s.openDirect(&dm)
	return &dm, nil
}

// ── typing ─────────────────────────────────────────────────────────────────

// typingFor is how long "typing…" lasts after the last keystroke report; the
// client reports every few seconds while the person types.
const typingFor = 6 * time.Second

// typingBoard remembers who is typing to whom. It lives in memory only: it is
// a passing signal, never worth a database write per keystroke.
type typingBoard struct {
	mu sync.Mutex
	at map[string]time.Time
}

var typing = &typingBoard{at: map[string]time.Time{}}

func (b *typingBoard) set(from, to identity.ID, on bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	key := from.String() + ">" + to.String()
	if on {
		b.at[key] = time.Now()
	} else {
		delete(b.at, key)
	}
	// Forget stale entries now and then so the board stays small.
	if len(b.at) > 1000 {
		for k, t := range b.at {
			if time.Since(t) > typingFor {
				delete(b.at, k)
			}
		}
	}
}

func (b *typingBoard) is(from, to identity.ID) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	t, ok := b.at[from.String()+">"+to.String()]
	return ok && time.Since(t) < typingFor
}

// ── notifications ──────────────────────────────────────────────────────────

// notifyAfter is how long a message may go unread before its notification:
// someone looking at the conversation reads it first and is not buzzed.
var notifyAfter = 4 * time.Second

// notifyDirect pushes a direct message to its recipient's phones when they
// have not read it shortly after it was sent (and it was not taken back).
func (s *Service) notifyDirect(ctx context.Context, dm message.Direct) {
	time.Sleep(notifyAfter)
	st, _, err := s.directStateOf(ctx, dm.To, dm.From)
	if err != nil || st.Blocked || !st.ReadAt.Before(dm.CreatedAt) {
		return
	}
	if current, err := s.getDirect(ctx, dm.ID); err != nil || !current.DeletedAt.IsZero() {
		return
	}
	name, _ := s.publicRef(ctx, dm.To, dm.From)["display_name"].(string)
	if name == "" {
		name = "New message"
	}
	body := strings.TrimSpace(dm.Body)
	if body == "" {
		body = s.attachmentLabel(ctx, &dm)
	}
	if len([]rune(body)) > 140 {
		body = string([]rune(body)[:139]) + "…"
	}
	s.Push(ctx, []identity.ID{dm.To}, PushNote{Title: name, Body: body, Kind: "dm", Peer: dm.From.String(), Collapse: "dm:" + dm.From.String()})
}

// ── actions ────────────────────────────────────────────────────────────────

// messageAction is a users.dm_* action on one of the caller's own messages.
type messageAction struct {
	name, summary string
	run           func(ctx context.Context, s *Service, me identity.ID, dm *message.Direct, body string) error
	s             *Service
}

func (a *messageAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: a.name, Summary: a.summary}
}

func (a *messageAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		ID   string `json:"id"`
		Body string `json:"body"`
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
	if dm.From != req.Caller.ID {
		return nil, errs.New(errs.CodePermission, "only its sender can change a message")
	}
	if !dm.DeletedAt.IsZero() {
		return nil, errs.Conflict("this message was deleted")
	}
	if err := a.run(ctx, a.s, req.Caller.ID, dm, strings.TrimSpace(in.Body)); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "message": directView(*dm)})
}

// saveDirect re-encrypts and stores a changed message.
func (s *Service) saveDirect(ctx context.Context, dm *message.Direct) error {
	plain := dm.Body
	sealed, err := s.sealDirect(dm.ID, plain)
	if err != nil {
		return err
	}
	dm.Body, dm.UpdatedAt = sealed, time.Now().UTC()
	err = s.R.Update(ctx, "directs", dm.ID, dm)
	dm.Body = plain
	return err
}

// hiddenDirect is one message a person deleted for themselves: the other side
// still has it.
type hiddenDirect struct {
	ID        string      `db:"id" json:"-"`
	UserID    identity.ID `db:"user_id" json:"user_id"`
	MessageID string      `db:"message_id" json:"message_id"`
	CreatedAt time.Time   `db:"created_at" json:"created_at"`
}

// hiddenDirects are the ids of the messages user deleted for themselves.
func (s *Service) hiddenDirects(ctx context.Context, user identity.ID) (map[string]bool, error) {
	var rows []hiddenDirect
	if err := s.R.List(ctx, "direct_hidden", database.Filter{Equal: map[string]any{"user_id": user.String()}}, &rows); err != nil {
		return nil, err
	}
	out := make(map[string]bool, len(rows))
	for _, r := range rows {
		out[r.MessageID] = true
	}
	return out, nil
}

// dmHide is users.dm_hide: delete one message of a conversation for the
// caller only, whoever sent it.
type dmHide struct{ s *Service }

func (a *dmHide) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "dm_hide", Summary: "Delete a message for yourself only"}
}

func (a *dmHide) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		ID string `json:"id"`
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
	row := &hiddenDirect{ID: req.Caller.ID.String() + ":" + id.String(), UserID: req.Caller.ID, MessageID: id.String(), CreatedAt: time.Now().UTC()}
	if err := a.s.R.DB.Create(ctx, "direct_hidden", row.ID, row); err != nil && errs.CodeOf(err) != errs.CodeAlreadyExists && errs.CodeOf(err) != errs.CodeConflict {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

func directLiveActions(s *Service) []api.Action {
	return []api.Action{
		&dmHide{s: s},
		&dmReact{s: s},
		&messageAction{s: s, name: "dm_edit", summary: "Change the text of a message you sent",
			run: func(ctx context.Context, s *Service, _ identity.ID, dm *message.Direct, body string) error {
				if body == "" && len(attachmentIDs(dm)) == 0 {
					return errs.InvalidArgument("body required")
				}
				if dm.AgentID != "" {
					return errs.New(errs.CodePermission, "an agent's answer can't be changed")
				}
				if body == dm.Body {
					return nil
				}
				dm.Body, dm.EditedAt = body, time.Now().UTC()
				return s.saveDirect(ctx, dm)
			}},
		&messageAction{s: s, name: "dm_unsend", summary: "Delete a message you sent, for both sides",
			run: func(ctx context.Context, s *Service, _ identity.ID, dm *message.Direct, _ string) error {
				// The text goes for good; the row stays so the conversation shows
				// "Message deleted" where it was, and replies to it still make sense.
				s.dropMessageFiles(ctx, dm)
				dm.Body, dm.DeletedAt = "", time.Now().UTC()
				return s.saveDirect(ctx, dm)
			}},
		&peerAction{s: s, name: "dm_typing", summary: "Tell a peer you are typing to them (or stopped)",
			run: func(ctx context.Context, s *Service, me, peer identity.ID) (map[string]any, error) {
				if blocked, _, err := s.directBlocked(ctx, me, peer); err != nil || blocked {
					return map[string]any{"ok": true}, nil // nothing to show anyone
				}
				typing.set(me, peer, true)
				return map[string]any{"ok": true}, nil
			}},
	}
}
