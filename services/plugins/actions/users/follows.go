package users

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/users/models/follow"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
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

// FollowCounts returns followers/following counts for an account. Only people
// count: agents and apps that follow (or are followed) are left out, matching
// the follow lists.
func (s *Service) FollowCounts(ctx context.Context, acc identity.ID) (followers, following int64, err error) {
	fl, err := s.Followers(ctx, acc, 0, 0)
	if err != nil {
		return 0, 0, err
	}
	fg, err := s.Following(ctx, acc, 0, 0)
	if err != nil {
		return 0, 0, err
	}
	return int64(len(fl)), int64(len(fg)), nil
}

// Following lists the people [acc] follows, newest first. Limit <= 0 means
// no limit.
func (s *Service) Following(ctx context.Context, acc identity.ID, limit, offset int) ([]identity.ID, error) {
	var list []follow.Follow
	if err := s.R.List(ctx, "follows", database.Filter{
		Equal: map[string]any{"follower_id": acc.String()}, OrderBy: "created_at", Asc: false,
	}, &list); err != nil {
		return nil, err
	}
	ids := make([]identity.ID, 0, len(list))
	for i := range list {
		ids = append(ids, list[i].FolloweeID)
	}
	return page(s.people(ctx, ids), limit, offset), nil
}

// Followers lists the people following [acc], newest first. Limit <= 0 means
// no limit.
func (s *Service) Followers(ctx context.Context, acc identity.ID, limit, offset int) ([]identity.ID, error) {
	var list []follow.Follow
	if err := s.R.List(ctx, "follows", database.Filter{
		Equal: map[string]any{"followee_id": acc.String()}, OrderBy: "created_at", Asc: false,
	}, &list); err != nil {
		return nil, err
	}
	ids := make([]identity.ID, 0, len(list))
	for i := range list {
		ids = append(ids, list[i].FollowerID)
	}
	return page(s.people(ctx, ids), limit, offset), nil
}

// people keeps the ids that belong to human accounts, dropping agents, apps
// and accounts that no longer exist.
func (s *Service) people(ctx context.Context, ids []identity.ID) []identity.ID {
	out := ids[:0]
	for _, id := range ids {
		if acc, err := s.GetAccount(ctx, id.String()); err == nil && acc.Kind == account.KindUser {
			out = append(out, id)
		}
	}
	return out
}

// page slices one page out of an in-memory list. Limit <= 0 means no limit.
func page[T any](list []T, limit, offset int) []T {
	if offset < 0 {
		offset = 0
	}
	if offset > len(list) {
		offset = len(list)
	}
	list = list[offset:]
	if limit > 0 && len(list) > limit {
		list = list[:limit]
	}
	return list
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
			if acc.Kind == account.KindBot {
				name = helper.BotName(profile, acc.Handle)
			}
			if name != "" {
				out["display_name"] = name
			}
			if headline, _ := profile["headline"].(string); headline != "" {
				out["headline"] = headline
			}
		}
		if avatar := helper.TreeAvatar(rec.Tree); avatar != "" {
			out["avatar"] = avatar
		}
	}
	// A chat with an agent draws the same face as the open conversation:
	// the bot record id (so a personal look matches) and the platform
	// humanoid stored on the bot. The public view can omit both.
	if acc.Kind == account.KindBot {
		if rec, ok := s.botOf(ctx, acc.ID); ok {
			out["bot_id"] = rec.ID.String()
			if rec.Name != "" {
				out["display_name"] = rec.Name
			}
		}
		if s.M != nil {
			if full, err := s.M.Get(ctx, acc.ID); err == nil && full != nil {
				if profile, ok := full.Tree["profile"].(map[string]any); ok {
					if h, ok := profile["humanoid"].(map[string]any); ok {
						out["humanoid"] = h
					}
					if out["display_name"] == acc.Handle {
						if name := helper.BotName(profile, acc.Handle); name != "" {
							out["display_name"] = name
						}
					}
				}
				if avatar := helper.TreeAvatar(full.Tree); avatar != "" {
					out["avatar"] = avatar
				}
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
