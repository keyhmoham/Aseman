package users

import (
	"context"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/users/models/follow"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
)

// Follow records that [follower] follows [followee]. Idempotent.
func (s *Service) Follow(ctx context.Context, follower, followee identity.ID) error {
	if follower.IsZero() || followee.IsZero() {
		return errs.InvalidArgument("follower and followee required")
	}
	if follower == followee {
		return errs.InvalidArgument("cannot follow yourself")
	}
	if _, err := s.GetAccount(ctx, followee.String()); err != nil {
		return err
	}
	// Idempotent: an existing follow is a no-op.
	exists, err := s.IsFollowing(ctx, follower, followee)
	if err != nil {
		return err
	}
	if exists {
		return nil
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	return s.R.CreateID(ctx, "follows", id, &follow.Follow{
		Entity:     entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		FollowerID: follower, FolloweeID: followee,
	})
}

// Unfollow removes a follow relationship. Idempotent.
func (s *Service) Unfollow(ctx context.Context, follower, followee identity.ID) error {
	if follower.IsZero() || followee.IsZero() {
		return errs.InvalidArgument("follower and followee required")
	}
	var list []follow.Follow
	if err := s.R.List(ctx, "follows", database.Filter{
		Equal: map[string]any{"follower_id": follower.String(), "followee_id": followee.String()},
	}, &list); err != nil {
		return err
	}
	for i := range list {
		_ = s.R.Delete(ctx, "follows", list[i].ID)
	}
	return nil
}

// IsFollowing reports whether [follower] follows [followee].
func (s *Service) IsFollowing(ctx context.Context, follower, followee identity.ID) (bool, error) {
	var list []follow.Follow
	if err := s.R.List(ctx, "follows", database.Filter{
		Equal: map[string]any{"follower_id": follower.String(), "followee_id": followee.String()},
	}, &list); err != nil {
		return false, err
	}
	return len(list) > 0, nil
}

// FollowCounts returns followers/following counts for an account.
func (s *Service) FollowCounts(ctx context.Context, acc identity.ID) (followers, following int64, err error) {
	var fl []follow.Follow
	if err := s.R.List(ctx, "follows", database.Filter{Equal: map[string]any{"followee_id": acc.String()}}, &fl); err != nil {
		return 0, 0, err
	}
	var fg []follow.Follow
	if err := s.R.List(ctx, "follows", database.Filter{Equal: map[string]any{"follower_id": acc.String()}}, &fg); err != nil {
		return 0, 0, err
	}
	return int64(len(fl)), int64(len(fg)), nil
}

// Following lists the accounts [acc] follows, newest first.
func (s *Service) Following(ctx context.Context, acc identity.ID, limit, offset int) ([]identity.ID, error) {
	var list []follow.Follow
	if err := s.R.List(ctx, "follows", database.Filter{
		Equal: map[string]any{"follower_id": acc.String()}, OrderBy: "created_at", Asc: false, Limit: limit, Offset: offset,
	}, &list); err != nil {
		return nil, err
	}
	out := make([]identity.ID, 0, len(list))
	for i := range list {
		out = append(out, list[i].FolloweeID)
	}
	return out, nil
}

// Followers lists the accounts following [acc], newest first.
func (s *Service) Followers(ctx context.Context, acc identity.ID, limit, offset int) ([]identity.ID, error) {
	var list []follow.Follow
	if err := s.R.List(ctx, "follows", database.Filter{
		Equal: map[string]any{"followee_id": acc.String()}, OrderBy: "created_at", Asc: false, Limit: limit, Offset: offset,
	}, &list); err != nil {
		return nil, err
	}
	out := make([]identity.ID, 0, len(list))
	for i := range list {
		out = append(out, list[i].FollowerID)
	}
	return out, nil
}

// accountRefs resolves a list of account ids into their public summaries.
func (s *Service) accountRefs(ctx context.Context, ids []identity.ID) []map[string]any {
	out := make([]map[string]any, 0, len(ids))
	for _, id := range ids {
		acc, err := s.GetAccount(ctx, id.String())
		if err != nil {
			continue
		}
		out = append(out, s.publicRef(ctx, identity.ID{}, acc.ID))
	}
	return out
}

// publicRef renders an account as others see it: handle, kind, status and the
// public profile fields a client shows next to a name.
func (s *Service) publicRef(ctx context.Context, viewer, id identity.ID) map[string]any {
	acc, err := s.GetAccount(ctx, id.String())
	if err != nil {
		return map[string]any{"id": id.String()}
	}
	out := map[string]any{"id": acc.ID.String(), "handle": acc.Handle, "kind": acc.Kind, "status": acc.Status, "display_name": acc.Handle}
	if rec, e := s.M.View(ctx, viewer, acc.ID); e == nil && rec != nil {
		if profile, ok := rec.Tree["profile"].(map[string]any); ok {
			name := helper.PersonName(profile, acc.Handle)
			if string(acc.Kind) == "bot" {
				name = helper.BotName(profile, acc.Handle)
			}
			if name != "" {
				out["display_name"] = name
			}
			if avatar, _ := profile["avatar"].(string); avatar != "" {
				out["avatar"] = avatar
			}
			if headline, _ := profile["headline"].(string); headline != "" {
				out["headline"] = headline
			}
		}
	}
	return out
}

// followAction implements users.follow.
type followAction struct{ s *Service }

func (a *followAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "follow", Summary: "Follow an account"}
}
func (a *followAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Account string `json:"account"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	target, err := identity.Parse(in.Account)
	if err != nil {
		return nil, errs.InvalidArgument("invalid account id")
	}
	if err := a.s.Follow(ctx, req.Caller.ID, target); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "following": true})
}

// unfollowAction implements users.unfollow.
type unfollowAction struct{ s *Service }

func (a *unfollowAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "unfollow", Summary: "Unfollow an account"}
}
func (a *unfollowAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Account string `json:"account"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	target, err := identity.Parse(in.Account)
	if err != nil {
		return nil, errs.InvalidArgument("invalid account id")
	}
	if err := a.s.Unfollow(ctx, req.Caller.ID, target); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "following": false})
}

// followingListAction implements users.following_list.
type followingListAction struct{ s *Service }

func (a *followingListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "following_list", Summary: "List accounts an account follows"}
}
func (a *followingListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Account string `json:"account,omitempty"`
		Limit   int    `json:"limit,omitempty"`
		Offset  int    `json:"offset,omitempty"`
	}
	_ = helper.Decode(req, &in)
	ref := req.Caller.ID
	if in.Account != "" {
		id, err := identity.Parse(in.Account)
		if err != nil {
			return nil, errs.InvalidArgument("invalid account id")
		}
		ref = id
	}
	limit, offset := helper.Paging(in.Limit, in.Offset, 50, 200)
	ids, err := a.s.Following(ctx, ref, limit, offset)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"users": a.s.accountRefs(ctx, ids)})
}

// followersListAction implements users.followers_list.
type followersListAction struct{ s *Service }

func (a *followersListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "followers_list", Summary: "List an account's followers"}
}
func (a *followersListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Account string `json:"account,omitempty"`
		Limit   int    `json:"limit,omitempty"`
		Offset  int    `json:"offset,omitempty"`
	}
	_ = helper.Decode(req, &in)
	ref := req.Caller.ID
	if in.Account != "" {
		id, err := identity.Parse(in.Account)
		if err != nil {
			return nil, errs.InvalidArgument("invalid account id")
		}
		ref = id
	}
	limit, offset := helper.Paging(in.Limit, in.Offset, 50, 200)
	ids, err := a.s.Followers(ctx, ref, limit, offset)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"users": a.s.accountRefs(ctx, ids)})
}
