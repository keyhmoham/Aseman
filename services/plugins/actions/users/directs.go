package users

import (
	"context"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/crypto"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// directStatesTable holds each person's own view of each conversation.
const directStatesTable = "direct_states"

// directState is one person's side of a direct conversation with a peer:
// how far they have read, from when they see it (a deleted chat starts again
// after ClearedAt, for them only), whether they blocked the peer and when
// they pinned the chat (zero: not pinned).
type directState struct {
	ID        string      `db:"id" json:"-"`
	UserID    identity.ID `db:"user_id" json:"user_id"`
	PeerID    identity.ID `db:"peer_id" json:"peer_id"`
	ReadAt    time.Time   `db:"read_at" json:"read_at"`
	ClearedAt time.Time   `db:"cleared_at" json:"cleared_at"`
	Blocked   bool        `db:"blocked" json:"blocked"`
	PinnedAt  time.Time   `db:"pinned_at" json:"pinned_at"`
	UpdatedAt time.Time   `db:"updated_at" json:"updated_at"`
}

func directStateID(user, peer identity.ID) string { return user.String() + ":" + peer.String() }

// directStateOf reads user's side of the conversation with peer (empty when
// they never read, deleted or blocked it).
func (s *Service) directStateOf(ctx context.Context, user, peer identity.ID) (*directState, bool, error) {
	var st directState
	err := s.R.GetString(ctx, directStatesTable, directStateID(user, peer), &st)
	if errs.CodeOf(err) == errs.CodeNotFound {
		return &directState{ID: directStateID(user, peer), UserID: user, PeerID: peer}, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return &st, true, nil
}

// updateDirectState changes user's side of the conversation with peer.
func (s *Service) updateDirectState(ctx context.Context, user, peer identity.ID, change func(*directState)) (*directState, error) {
	st, exists, err := s.directStateOf(ctx, user, peer)
	if err != nil {
		return nil, err
	}
	change(st)
	st.UpdatedAt = time.Now().UTC()
	if exists {
		err = s.R.DB.Update(ctx, directStatesTable, st.ID, st)
	} else {
		err = s.R.DB.Create(ctx, directStatesTable, st.ID, st)
	}
	return st, err
}

// directStates are all of user's conversation states, by peer.
func (s *Service) directStates(ctx context.Context, user identity.ID) (map[string]directState, error) {
	var rows []directState
	if err := s.R.List(ctx, directStatesTable, database.Filter{Equal: map[string]any{"user_id": user.String()}}, &rows); err != nil {
		return nil, err
	}
	out := make(map[string]directState, len(rows))
	for _, r := range rows {
		out[r.PeerID.String()] = r
	}
	return out, nil
}

// directBlocked reports whether either side blocked the other: a message
// cannot be sent either way. byMe says the sender is the one who blocked.
func (s *Service) directBlocked(ctx context.Context, from, to identity.ID) (blocked, byMe bool, err error) {
	mine, _, err := s.directStateOf(ctx, from, to)
	if err != nil {
		return false, false, err
	}
	if mine.Blocked {
		return true, true, nil
	}
	theirs, _, err := s.directStateOf(ctx, to, from)
	if err != nil {
		return false, false, err
	}
	return theirs.Blocked, false, nil
}

// Direct messages are encrypted at rest with AES-256-GCM under a key derived
// from the node's identity key, each bound to its own message id, so a copy
// of the database (or a backup) does not reveal what people wrote. The node
// itself still reads them to deliver them (and to let agents answer): this is
// encryption at rest, not end to end.

func directContext(id identity.ID) string { return "users/direct/v1/" + id.String() }

func (s *Service) sealDirect(id identity.ID, body string) (string, error) {
	sealed, err := crypto.SealSecret(body, s.K.Env()["node_private_key"], directContext(id))
	if err != nil {
		return "", errs.New(errs.CodeUnavailable, "message encryption is unavailable on this node")
	}
	return sealed, nil
}

// openDirect returns a message's text: decrypted, or as it is for one stored
// before messages were encrypted.
func (s *Service) openDirect(dm *message.Direct) {
	if !strings.HasPrefix(dm.Body, crypto.SecretPrefix) {
		return
	}
	plain, err := crypto.OpenSecret(dm.Body, s.K.Env()["node_private_key"], directContext(dm.ID))
	if err != nil {
		dm.Body = "(this message could not be decrypted)"
		return
	}
	dm.Body = plain
}

// storeDirect encrypts and saves a direct message.
func (s *Service) storeDirect(ctx context.Context, dm *message.Direct) error {
	plain := dm.Body
	sealed, err := s.sealDirect(dm.ID, plain)
	if err != nil {
		return err
	}
	dm.Body = sealed
	err = s.R.CreateID(ctx, "directs", dm.ID, dm)
	dm.Body = plain
	return err
}

// peerAction is a users.dm_* action on one conversation: {"peer": id}.
type peerAction struct {
	s       *Service
	name    string
	summary string
	// self allows the caller's own Saved Messages (a conversation with themselves).
	self bool
	run  func(ctx context.Context, s *Service, me, peer identity.ID) (map[string]any, error)
}

func (a *peerAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: a.name, Summary: a.summary}
}

func (a *peerAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Peer string `json:"peer"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	peer, err := identity.Parse(in.Peer)
	if err != nil {
		return nil, err
	}
	if peer == req.Caller.ID && !a.self {
		return nil, errs.InvalidArgument("that is you")
	}
	out, err := a.run(ctx, a.s, req.Caller.ID, peer)
	if err != nil {
		return nil, err
	}
	return helper.JSON(out)
}

// directActions are the conversation-level actions: read, delete (for the
// caller only), block and unblock, pin and unpin.
func directActions(s *Service) []api.Action {
	return []api.Action{
		&peerAction{s: s, name: "dm_read", summary: "Mark a direct conversation read up to now", self: true,
			run: func(ctx context.Context, s *Service, me, peer identity.ID) (map[string]any, error) {
				st, err := s.updateDirectState(ctx, me, peer, func(st *directState) { st.ReadAt = time.Now().UTC() })
				if err != nil {
					return nil, err
				}
				return map[string]any{"ok": true, "read_at": st.ReadAt}, nil
			}},
		&peerAction{s: s, name: "dm_delete", summary: "Delete a direct conversation for the caller only", self: true,
			run: func(ctx context.Context, s *Service, me, peer identity.ID) (map[string]any, error) {
				// Only the caller's view is cleared: the peer keeps their copy, and
				// a later message starts the conversation afresh for the caller.
				_, err := s.updateDirectState(ctx, me, peer, func(st *directState) {
					now := time.Now().UTC()
					st.ClearedAt, st.ReadAt = now, now
				})
				if err != nil {
					return nil, err
				}
				return map[string]any{"ok": true}, nil
			}},
		&peerAction{s: s, name: "dm_block", summary: "Block a person: neither of you can message the other",
			run: func(ctx context.Context, s *Service, me, peer identity.ID) (map[string]any, error) {
				if _, err := s.updateDirectState(ctx, me, peer, func(st *directState) { st.Blocked = true }); err != nil {
					return nil, err
				}
				return map[string]any{"ok": true, "blocked": true}, nil
			}},
		&peerAction{s: s, name: "dm_unblock", summary: "Unblock a person",
			run: func(ctx context.Context, s *Service, me, peer identity.ID) (map[string]any, error) {
				if _, err := s.updateDirectState(ctx, me, peer, func(st *directState) { st.Blocked = false }); err != nil {
					return nil, err
				}
				return map[string]any{"ok": true, "blocked": false}, nil
			}},
		&peerAction{s: s, name: "dm_pin", summary: "Pin a direct conversation to the top of the caller's list", self: true,
			run: func(ctx context.Context, s *Service, me, peer identity.ID) (map[string]any, error) {
				st, err := s.updateDirectState(ctx, me, peer, func(st *directState) { st.PinnedAt = time.Now().UTC() })
				if err != nil {
					return nil, err
				}
				return map[string]any{"ok": true, "pinned_at": st.PinnedAt}, nil
			}},
		&peerAction{s: s, name: "dm_unpin", summary: "Unpin a direct conversation", self: true,
			run: func(ctx context.Context, s *Service, me, peer identity.ID) (map[string]any, error) {
				if _, err := s.updateDirectState(ctx, me, peer, func(st *directState) { st.PinnedAt = time.Time{} }); err != nil {
					return nil, err
				}
				return map[string]any{"ok": true}, nil
			}},
	}
}

// encryptLegacyDirects encrypts, once, the direct messages stored before
// messages were encrypted. It runs when the namespace mounts; a node without
// an identity key keeps them as they are (and logs it) rather than refusing to
// start.
func (s *Service) encryptLegacyDirects(ctx context.Context) error {
	if s.K.Env()["node_private_key"] == "" {
		return nil
	}
	var rows []message.Direct
	if err := s.R.List(ctx, "directs", database.Filter{}, &rows); err != nil {
		return nil // nothing to migrate yet (a fresh node)
	}
	for i := range rows {
		dm := &rows[i]
		if strings.HasPrefix(dm.Body, crypto.SecretPrefix) {
			continue
		}
		sealed, err := s.sealDirect(dm.ID, dm.Body)
		if err != nil {
			if s.L != nil {
				s.L.Warn("direct messages stay unencrypted: no key", "error", err)
			}
			return nil
		}
		dm.Body = sealed
		if err := s.R.Update(ctx, "directs", dm.ID, dm); err != nil && s.L != nil {
			s.L.Warn("encrypt stored direct message", "id", dm.ID.String(), "error", err)
		}
	}
	return nil
}
