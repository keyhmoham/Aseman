package posts

import (
	"context"
	"sort"
	"strings"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/posts/models"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// searchWindow bounds how many of the newest posts a search scans per source.
const searchWindow = 1000

// FollowingSearch finds, by body text, the posts of the caller's Following
// feed: the top-level posts of the authors they follow (and their own) and
// those of every space they are a member of, newest first.
func (s *Service) FollowingSearch(ctx context.Context, caller identity.ID, query string, limit, offset int) ([]post.Post, error) {
	authors, err := s.ConnectedAuthors(ctx, caller)
	if err != nil {
		return nil, err
	}
	authors = append(authors, caller.String())
	spaces, err := s.mySpaceIDs(ctx, caller)
	if err != nil {
		return nil, err
	}
	sources := []map[string][]any{{"author_id": toAnyList(authors)}}
	if len(spaces) > 0 {
		sources = append(sources, map[string][]any{"space_id": toAnyList(spaces)})
	}
	q := strings.ToLower(strings.TrimSpace(query))
	seen := map[string]bool{}
	var out []post.Post
	for _, in := range sources {
		var list []post.Post
		if err := s.R.List(ctx, "posts", database.Filter{
			Equal: map[string]any{"parent_id": zeroID}, In: in,
			OrderBy: "created_at", Asc: false, Limit: searchWindow,
		}, &list); err != nil {
			return nil, err
		}
		for _, p := range list {
			if seen[p.ID.String()] || (q != "" && !strings.Contains(strings.ToLower(p.Body), q)) {
				continue
			}
			seen[p.ID.String()] = true
			out = append(out, p)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	if offset > len(out) {
		offset = len(out)
	}
	out = out[offset:]
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}
