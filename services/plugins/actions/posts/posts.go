// Package posts implements the posts namespace: user-published feed entries,
// likes and comments across the federated network.
package posts

import (
	"context"
	"encoding/json"
	"sort"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/posts/models"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// Service implements post operations.
type Service struct {
	K api.Kernel
	R *repo.Repo
	L *logger.Logger
}

// NewService builds the posts service.
func NewService(k api.Kernel, r *repo.Repo, log *logger.Logger) *Service {
	return &Service{K: k, R: r, L: log.Named("posts")}
}

// Create publishes a post. When SpaceID is set the post is attached to the
// workspace; otherwise it is global.
func (s *Service) Create(ctx context.Context, author identity.ID, spaceID, parentID identity.ID, body string, tags, media []string) (*post.Post, error) {
	if body == "" {
		return nil, errs.InvalidArgument("post body required")
	}
	if len(body) > 4000 {
		return nil, errs.InvalidArgument("post body too long (max 4000)")
	}
	node := s.K.NodeID()
	id, err := identity.New(node)
	if err != nil {
		return nil, err
	}
	tagsJSON, _ := json.Marshal(tags)
	mediaJSON, _ := json.Marshal(media)
	now := time.Now().UTC()
	p := &post.Post{
		Entity:   entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		AuthorID: author, SpaceID: spaceID, ParentID: parentID,
		Body: body, Tags: string(tagsJSON), Media: string(mediaJSON),
		LikedBy: "[]", Likes: 0,
	}
	if err := s.R.CreateID(ctx, "posts", id, p); err != nil {
		return nil, err
	}
	s.L.Info("post created", "post", id.String(), "author", author.String())
	return p, nil
}

// Get loads a post.
func (s *Service) Get(ctx context.Context, id identity.ID) (*post.Post, error) {
	p := &post.Post{}
	if err := s.R.Get(ctx, "posts", id, p); err != nil {
		return nil, err
	}
	return p, nil
}

// Delete removes a post authored by the caller (comments are left orphaned).
func (s *Service) Delete(ctx context.Context, caller identity.ID, id identity.ID) error {
	p, err := s.Get(ctx, id)
	if err != nil {
		return err
	}
	if p.AuthorID != caller {
		return errs.Permission("only the author can delete a post")
	}
	return s.R.Delete(ctx, "posts", id)
}

// Like adds the caller to the liked set.
func (s *Service) Like(ctx context.Context, caller identity.ID, id identity.ID) error {
	p, err := s.Get(ctx, id)
	if err != nil {
		return err
	}
	if !s.visible(ctx, caller, p, map[string]bool{}) {
		return errs.Permission("not a member of the space")
	}
	if p.HasLiked(caller) {
		return nil
	}
	liked := append(p.ParseLikedBy(), caller.String())
	return s.setLikes(ctx, p, liked)
}

// Unlike removes the caller from the liked set.
func (s *Service) Unlike(ctx context.Context, caller identity.ID, id identity.ID) error {
	p, err := s.Get(ctx, id)
	if err != nil {
		return err
	}
	liked := p.ParseLikedBy()
	kept := liked[:0]
	for _, v := range liked {
		if v != caller.String() {
			kept = append(kept, v)
		}
	}
	return s.setLikes(ctx, p, kept)
}

func (s *Service) setLikes(ctx context.Context, p *post.Post, liked []string) error {
	likedJSON, _ := json.Marshal(liked)
	p.LikedBy = string(likedJSON)
	p.Likes = int64(len(liked))
	p.UpdatedAt = time.Now().UTC()
	return s.R.Update(ctx, "posts", p.ID, p)
}

// Comment adds a child post under the parent.
func (s *Service) Comment(ctx context.Context, author identity.ID, parentID identity.ID, body string) (*post.Post, error) {
	parent, err := s.Get(ctx, parentID)
	if err != nil {
		return nil, err
	}
	if !s.visible(ctx, author, parent, map[string]bool{}) {
		return nil, errs.Permission("not a member of the space")
	}
	// A comment lives where its post lives, so workspace privacy carries over.
	return s.Create(ctx, author, parent.SpaceID, parentID, body, nil, nil)
}

// Comments lists the child posts of a parent.
func (s *Service) Comments(ctx context.Context, parentID identity.ID, limit int) ([]post.Post, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	var out []post.Post
	if err := s.R.List(ctx, "posts", database.Filter{
		Equal: map[string]any{"parent_id": parentID.String()}, OrderBy: "created_at", Asc: true, Limit: limit,
	}, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// Feed returns the global feed, optionally restricted to the authors the
// caller is connected to (shares a workspace with) and/or a single space.
//
// Privacy rules:
//   - Global (no space, not following) lists only public top-level posts not
//     attached to any workspace, so private workspace posts never leak.
//   - A space-scoped feed requires the caller to be a member of that space.
//   - The following feed lists top-level posts by connected authors.
func (s *Service) Feed(ctx context.Context, caller identity.ID, spaceID identity.ID, following bool, limit, offset int) ([]post.Post, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	f := database.Filter{
		Equal:   map[string]any{"parent_id": zeroID},
		OrderBy: "created_at", Asc: false, Limit: limit, Offset: offset,
	}
	switch {
	case !spaceID.IsZero():
		member, err := s.isMember(ctx, caller, spaceID)
		if err != nil {
			return nil, err
		}
		if !member {
			return nil, errs.Permission("not a member of the space")
		}
		f.Equal["space_id"] = spaceID.String()
	case following:
		authors, err := s.ConnectedAuthors(ctx, caller)
		if err != nil {
			return nil, err
		}
		authors = append(authors, caller.String())
		f.In = map[string][]any{"author_id": toAnyList(authors)}
	default:
		// Global feed: public posts not tied to any workspace, the featured
		// ones (imported traders' latest posts) first.
		return s.globalFeed(ctx, limit, offset)
	}
	var out []post.Post
	if err := s.R.List(ctx, "posts", f, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// SpacesFeed aggregates the private top-level posts of every workspace the
// caller is a member of, newest first. This powers the "Spaces" feed tab.
func (s *Service) SpacesFeed(ctx context.Context, caller identity.ID, limit, offset int) ([]post.Post, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	ids, err := s.mySpaceIDs(ctx, caller)
	if err != nil {
		return nil, err
	}
	if len(ids) == 0 {
		return []post.Post{}, nil
	}
	var out []post.Post
	if err := s.R.List(ctx, "posts", database.Filter{
		Equal:   map[string]any{"parent_id": zeroID},
		In:      map[string][]any{"space_id": toAnyList(ids)},
		OrderBy: "created_at", Asc: false, Limit: limit, Offset: offset,
	}, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// mySpaceIDs returns the ids of the spaces the caller is a member of.
func (s *Service) mySpaceIDs(ctx context.Context, caller identity.ID) ([]string, error) {
	var mems []membershipRow
	if err := s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"member_id": caller.String()},
	}, &mems); err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var ids []string
	for _, m := range mems {
		if m.SpaceID != "" && !seen[m.SpaceID] {
			seen[m.SpaceID] = true
			ids = append(ids, m.SpaceID)
		}
	}
	return ids, nil
}

// isMember reports whether the caller is a member of the space.
func (s *Service) isMember(ctx context.Context, caller, spaceID identity.ID) (bool, error) {
	ids, err := s.mySpaceIDs(ctx, caller)
	if err != nil {
		return false, err
	}
	for _, id := range ids {
		if id == spaceID.String() {
			return true, nil
		}
	}
	return false, nil
}

// UserPosts lists top-level posts authored by an account.
func (s *Service) UserPosts(ctx context.Context, author identity.ID, limit, offset int) ([]post.Post, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	var out []post.Post
	if err := s.R.List(ctx, "posts", database.Filter{
		Equal:   map[string]any{"author_id": author.String(), "parent_id": zeroID},
		OrderBy: "created_at", Asc: false,
		Limit: limit, Offset: offset,
	}, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// ConnectedAuthors returns the accounts that share a workspace membership with
// caller (the caller's social graph).
func (s *Service) ConnectedAuthors(ctx context.Context, caller identity.ID) ([]string, error) {
	var myMems []membershipRow
	if err := s.R.List(ctx, "memberships", database.Filter{
		Equal: map[string]any{"member_id": caller.String()},
	}, &myMems); err != nil {
		return nil, err
	}
	spaceSet := map[string]bool{}
	for _, m := range myMems {
		spaceSet[m.SpaceID] = true
	}
	var spaces []any
	for sp := range spaceSet {
		spaces = append(spaces, sp)
	}
	if len(spaces) == 0 {
		return nil, nil
	}
	var coMems []membershipRow
	if err := s.R.List(ctx, "memberships", database.Filter{
		In: map[string][]any{"space_id": spaces},
	}, &coMems); err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var authors []string
	for _, m := range coMems {
		if m.MemberID == caller.String() || seen[m.MemberID] {
			continue
		}
		seen[m.MemberID] = true
		authors = append(authors, m.MemberID)
	}
	return authors, nil
}

type membershipRow struct {
	SpaceID  string `db:"space_id" json:"space_id"`
	MemberID string `db:"member_id" json:"member_id"`
}

func toAnyList(in []string) []any {
	out := make([]any, len(in))
	for i, v := range in {
		out[i] = v
	}
	return out
}

// Leaderboard ranks top post authors by total likes across their posts.
type LeaderboardEntry struct {
	AuthorID string `json:"author_id"`
	Handle   string `json:"handle"`
	Posts    int64  `json:"posts"`
	Likes    int64  `json:"likes"`
	Score    int64  `json:"score"`
}

// Leaderboard aggregates engagement over the newest N top-level posts and
// ranks the most-liked authors first.
func (s *Service) Leaderboard(ctx context.Context, limit int) ([]LeaderboardEntry, error) {
	if limit <= 0 || limit > 50 {
		limit = 10
	}
	var list []post.Post
	if err := s.R.List(ctx, "posts", database.Filter{
		Equal: map[string]any{"parent_id": zeroID}, OrderBy: "created_at", Asc: false, Limit: 1000,
	}, &list); err != nil {
		return nil, err
	}
	type agg struct {
		handle string
		posts  int64
		likes  int64
	}
	acc := map[string]*agg{}
	for i := range list {
		key := list[i].AuthorID.String()
		a, ok := acc[key]
		if !ok {
			a = &agg{}
			acc[key] = a
		}
		a.posts++
		a.likes += list[i].Likes
	}
	var out []LeaderboardEntry
	for id, a := range acc {
		handle := "u_" + id
		if len(id) >= 6 {
			handle = "u_" + id[len(id)-6:]
		}
		var accRow account.Account
		if err := s.R.Get(ctx, "accounts", mustParse(id), &accRow); err == nil {
			handle = accRow.Handle
		}
		out = append(out, LeaderboardEntry{
			AuthorID: id, Handle: handle, Posts: a.posts, Likes: a.likes,
			Score: a.likes*100 + a.posts,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Score > out[j].Score })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func mustParse(id string) identity.ID {
	v, _ := identity.Parse(id)
	return v
}
