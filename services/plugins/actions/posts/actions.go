package posts

import (
	"context"
	"strings"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/posts/models"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// zeroID is the universal id string of a zero (top-level) parent.
const zeroID = "00000000000000000000000000000000"

// postCreateAction implements posts.post_create.
type postCreateAction struct{ s *Service }

func (a *postCreateAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "post_create", Summary: "Publish a post (optionally into a workspace)"}
}
func (a *postCreateAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Body   string   `json:"body"`
		Space  string   `json:"space,omitempty"`
		Tags   []string `json:"tags,omitempty"`
		Media  []string `json:"media,omitempty"`
		Parent string   `json:"parent,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	var spaceID, parentID identity.ID
	if in.Space != "" {
		var err error
		spaceID, err = identity.Parse(in.Space)
		if err != nil {
			return nil, errs.InvalidArgument("invalid space id")
		}
		member, err := a.s.isMember(ctx, req.Caller.ID, spaceID)
		if err != nil {
			return nil, err
		}
		if !member {
			return nil, errs.Permission("not a member of the space")
		}
	}
	if in.Parent != "" {
		var err error
		parentID, err = identity.Parse(in.Parent)
		if err != nil {
			return nil, errs.InvalidArgument("invalid parent id")
		}
	}
	p, err := a.s.Create(ctx, req.Caller.ID, spaceID, parentID, in.Body, in.Tags, in.Media)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"post_id": p.ID.String(), "ok": true})
}

// postGetAction implements posts.post_get.
type postGetAction struct{ s *Service }

func (a *postGetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "post_get", Summary: "Fetch a single post"}
}
func (a *postGetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Post string `json:"post"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Post)
	if err != nil {
		return nil, errs.InvalidArgument("invalid post id")
	}
	if resp, ok, err := helper.ProxyIfRemote(ctx, a.s.K, in.Post, "posts", "post_get", req); ok {
		return resp, err
	}
	p, err := a.s.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	views := a.s.Views(ctx, req.Caller.ID, []post.Post{*p})
	if len(views) == 0 {
		return nil, errs.Permission("not a member of the space")
	}
	return helper.JSON(views[0])
}

// postDeleteAction implements posts.post_delete.
type postDeleteAction struct{ s *Service }

func (a *postDeleteAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "post_delete", Summary: "Delete one of my posts"}
}
func (a *postDeleteAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Post string `json:"post"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Post)
	if err != nil {
		return nil, errs.InvalidArgument("invalid post id")
	}
	if err := a.s.Delete(ctx, req.Caller.ID, id); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

// postFeedAction implements posts.post_feed.
type postFeedAction struct{ s *Service }

func (a *postFeedAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "post_feed", Summary: "Browse the global or following feed"}
}
func (a *postFeedAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Following bool   `json:"following,omitempty"`
		Space     string `json:"space,omitempty"`
		Limit     int    `json:"limit,omitempty"`
		Offset    int    `json:"offset,omitempty"`
	}
	_ = helper.Decode(req, &in)
	var spaceID identity.ID
	if in.Space != "" {
		var err error
		spaceID, err = identity.Parse(in.Space)
		if err != nil {
			return nil, errs.InvalidArgument("invalid space id")
		}
	}
	feed, err := a.s.Feed(ctx, req.Caller.ID, spaceID, in.Following, in.Limit, in.Offset)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"posts": a.s.Views(ctx, req.Caller.ID, feed)})
}

// postUserPostsAction implements posts.post_user_posts.
type postUserPostsAction struct{ s *Service }

func (a *postUserPostsAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "post_user_posts", Summary: "List posts authored by a user"}
}
func (a *postUserPostsAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		User   string `json:"user"`
		Limit  int    `json:"limit,omitempty"`
		Offset int    `json:"offset,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.User)
	if err != nil {
		return nil, errs.InvalidArgument("invalid user id")
	}
	if resp, ok, err := helper.ProxyIfRemote(ctx, a.s.K, in.User, "posts", "post_user_posts", req); ok {
		return resp, err
	}
	list, err := a.s.UserPosts(ctx, id, in.Limit, in.Offset)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"posts": a.s.Views(ctx, req.Caller.ID, list)})
}

// postLikeAction implements posts.post_like.
type postLikeAction struct{ s *Service }

func (a *postLikeAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "post_like", Summary: "Like a post"}
}
func (a *postLikeAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Post string `json:"post"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Post)
	if err != nil {
		return nil, errs.InvalidArgument("invalid post id")
	}
	if err := a.s.Like(ctx, req.Caller.ID, id); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

// postUnlikeAction implements posts.post_unlike.
type postUnlikeAction struct{ s *Service }

func (a *postUnlikeAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "post_unlike", Summary: "Remove a like from a post"}
}
func (a *postUnlikeAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Post string `json:"post"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Post)
	if err != nil {
		return nil, errs.InvalidArgument("invalid post id")
	}
	if err := a.s.Unlike(ctx, req.Caller.ID, id); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

// postCommentAction implements posts.post_comment.
type postCommentAction struct{ s *Service }

func (a *postCommentAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "post_comment", Summary: "Comment on a post"}
}
func (a *postCommentAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Post string `json:"post"`
		Body string `json:"body"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Post)
	if err != nil {
		return nil, errs.InvalidArgument("invalid post id")
	}
	p, err := a.s.Comment(ctx, req.Caller.ID, id, in.Body)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"comment_id": p.ID.String(), "ok": true})
}

// postCommentsAction implements posts.post_comments.
type postCommentsAction struct{ s *Service }

func (a *postCommentsAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "post_comments", Summary: "List the comments on a post"}
}
func (a *postCommentsAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Post  string `json:"post"`
		Limit int    `json:"limit,omitempty"`
	}
	_ = helper.Decode(req, &in)
	id, err := identity.Parse(in.Post)
	if err != nil {
		return nil, errs.InvalidArgument("invalid post id")
	}
	parent, err := a.s.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	if len(a.s.Views(ctx, req.Caller.ID, []post.Post{*parent})) == 0 {
		return nil, errs.Permission("not a member of the space")
	}
	list, err := a.s.Comments(ctx, id, in.Limit)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"comments": a.s.Views(ctx, req.Caller.ID, list)})
}

// BuildActions assembles the posts namespace actions.
func BuildActions(s *Service) []api.Action {
	return []api.Action{
		&postCreateAction{s: s}, &postGetAction{s: s}, &postDeleteAction{s: s},
		&postFeedAction{s: s}, &postUserPostsAction{s: s},
		&postSpacesFeedAction{s: s},
		&postLikeAction{s: s}, &postUnlikeAction{s: s},
		&postCommentAction{s: s}, &postCommentsAction{s: s},
		&postSearchAction{s: s}, &postLeaderboardAction{s: s},
		&postImportAction{s: s},
	}
}

// postSpacesFeedAction implements posts.spaces_feed.
type postSpacesFeedAction struct{ s *Service }

func (a *postSpacesFeedAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "spaces_feed", Summary: "Aggregate the private posts of all workspaces I am a member of"}
}
func (a *postSpacesFeedAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Limit  int `json:"limit,omitempty"`
		Offset int `json:"offset,omitempty"`
	}
	_ = helper.Decode(req, &in)
	feed, err := a.s.SpacesFeed(ctx, req.Caller.ID, in.Limit, in.Offset)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"posts": a.s.Views(ctx, req.Caller.ID, feed)})
}

// postLeaderboardAction implements posts.leaderboard.
type postLeaderboardAction struct{ s *Service }

func (a *postLeaderboardAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "leaderboard", Summary: "Rank top post authors by engagement"}
}
func (a *postLeaderboardAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Limit int `json:"limit,omitempty"`
	}
	_ = helper.Decode(req, &in)
	board, err := a.s.Leaderboard(ctx, in.Limit)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"leaderboard": board})
}

// postSearchAction implements posts.post_search.
type postSearchAction struct{ s *Service }

func (a *postSearchAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "post_search", Summary: "Search top-level posts by body text"}
}
func (a *postSearchAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Query  string `json:"query"`
		Limit  int    `json:"limit,omitempty"`
		Offset int    `json:"offset,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	limit, offset := helper.Paging(in.Limit, in.Offset, 20, 50)
	var list []post.Post
	if err := a.s.R.List(ctx, "posts", database.Filter{
		Equal: map[string]any{"parent_id": zeroID}, OrderBy: "created_at", Asc: false, Limit: limit + offset,
	}, &list); err != nil {
		return nil, err
	}
	q := strings.ToLower(strings.TrimSpace(in.Query))
	var out []post.Post
	for _, p := range list {
		if q == "" || strings.Contains(strings.ToLower(p.Body), q) {
			out = append(out, p)
			if len(out) >= limit+offset {
				break
			}
		}
	}
	if offset > len(out) {
		offset = len(out)
	}
	out = out[offset:]
	if len(out) > limit {
		out = out[:limit]
	}
	return helper.JSON(map[string]any{"posts": a.s.Views(ctx, req.Caller.ID, out)})
}
