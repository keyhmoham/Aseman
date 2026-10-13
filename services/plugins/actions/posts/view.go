package posts

import (
	"context"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"strings"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/posts/models"
	"github.com/tradera/tradera/plugins/actions/support/metasvc"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// visible reports whether caller may read p: global posts are public, a
// workspace post needs workspace membership. member memoizes membership.
func (s *Service) visible(ctx context.Context, caller identity.ID, p *post.Post, member map[string]bool) bool {
	if p.SpaceID.IsZero() {
		return true
	}
	key := p.SpaceID.String()
	if ok, done := member[key]; done {
		return ok
	}
	ok, err := s.isMember(ctx, caller, p.SpaceID)
	member[key] = err == nil && ok
	return member[key]
}

// Views filters list to what caller may read and renders each post with its
// author, the caller's like, its comment count and decoded tags/media (file
// ids served by /v1/files/{id}/content).
func (s *Service) Views(ctx context.Context, caller identity.ID, list []post.Post) []map[string]any {
	member := map[string]bool{}
	authors := map[string]map[string]any{}
	out := make([]map[string]any, 0, len(list))
	for i := range list {
		p := &list[i]
		if !s.visible(ctx, caller, p, member) {
			continue
		}
		author, ok := authors[p.AuthorID.String()]
		if !ok {
			author = s.author(ctx, p.AuthorID)
			authors[p.AuthorID.String()] = author
		}
		comments, _ := s.R.Count(ctx, "posts", database.Filter{Equal: map[string]any{"parent_id": p.ID.String()}})
		view := map[string]any{
			"id": p.ID.String(), "author_id": p.AuthorID.String(), "author": author,
			"parent_id": p.ParentID.String(), "body": p.Body,
			"tags": nonNil(p.ParseTags()), "media": nonNil(p.ParseMedia()),
			"likes": p.Likes, "liked": !caller.IsZero() && p.HasLiked(caller),
			"comments": comments, "created_at": p.CreatedAt, "updated_at": p.UpdatedAt,
		}
		if !p.SpaceID.IsZero() {
			view["space_id"] = p.SpaceID.String()
		}
		out = append(out, view)
	}
	return out
}

func (s *Service) author(ctx context.Context, id identity.ID) map[string]any {
	out := map[string]any{"id": id.String()}
	var acc account.Account
	if s.R.Get(ctx, "accounts", id, &acc) == nil {
		out["handle"] = acc.Handle
		out["kind"] = string(acc.Kind)
		out["display_name"] = acc.Handle
	}
	m := metasvc.Service{K: s.K, R: s.R}
	if rec, err := m.View(ctx, identity.ID{}, id); err == nil && rec != nil {
		if profile, ok := rec.Tree["profile"].(map[string]any); ok {
			name := helper.PersonName(profile, acc.Handle)
			if acc.Kind == account.KindBot {
				name = helper.BotName(profile, acc.Handle)
			}
			if name != "" {
				out["display_name"] = name
			}
			if avatar, _ := profile["avatar"].(string); strings.TrimSpace(avatar) != "" {
				out["avatar"] = strings.TrimSpace(avatar)
			}
		}
	}
	return out
}

func nonNil(v []string) []string {
	if v == nil {
		return []string{}
	}
	return v
}
