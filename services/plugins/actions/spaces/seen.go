package spaces

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/jsonpatch"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// How far a person has read a project's conversation is kept on the node, in
// the project's own record, not on the device they read it on: a message read
// on the phone is read on the laptop too. It only ever moves forward.

func seenPath(accountID identity.ID) string { return "chat_seen/" + accountID.String() }

// seenIn reads an account's read cursor out of a space's metadata tree.
func seenIn(tree map[string]any, accountID identity.ID) time.Time {
	seen, _ := tree["chat_seen"].(map[string]any)
	text, _ := seen[accountID.String()].(string)
	at, err := time.Parse(time.RFC3339Nano, text)
	if err != nil {
		return time.Time{}
	}
	return at
}

// SeenAt is when the account last read the space's conversation (zero when never).
func (s *Service) SeenAt(ctx context.Context, accountID, spaceID identity.ID) time.Time {
	if s.M == nil {
		return time.Time{}
	}
	rec, err := s.M.Get(ctx, spaceID)
	if err != nil || rec == nil {
		return time.Time{}
	}
	return seenIn(rec.Tree, accountID)
}

// MarkSeen moves the account's read cursor in a space forward to [at] and
// returns where it now is. A cursor is never moved back, and never past now.
func (s *Service) MarkSeen(ctx context.Context, accountID, spaceID identity.ID, at time.Time) (time.Time, error) {
	if now := time.Now().UTC().Add(time.Minute); at.After(now) {
		at = now
	}
	current := s.SeenAt(ctx, accountID, spaceID)
	if !at.After(current) {
		return current, nil
	}
	at = at.UTC()
	if err := s.M.Patch(ctx, spaceID, jsonpatch.Patch{{Op: "set", Path: seenPath(accountID), Value: at.Format(time.RFC3339Nano)}}); err != nil {
		return current, err
	}
	return at, nil
}

func seenActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "spaces", Name: "seen_set", Summary: "Record how far the caller has read a workspace's conversation", Handler: s.seenSet},
	}
}

func (s *Service) seenSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string    `json:"space"`
		At    time.Time `json:"at"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spaceID, err := identity.Parse(in.Space)
	if err != nil {
		return nil, errs.InvalidArgument("invalid space id")
	}
	if _, err := s.SpaceMembership(ctx, spaceID, req.Caller.ID); err != nil {
		return nil, errs.Permission("not a member of the space")
	}
	if in.At.IsZero() {
		in.At = time.Now().UTC()
	}
	at, err := s.MarkSeen(ctx, req.Caller.ID, spaceID, in.At)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "seen_at": at})
}
