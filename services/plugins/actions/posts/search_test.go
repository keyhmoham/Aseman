package posts

import (
	"context"
	"testing"
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/posts/models"
	"github.com/tradera/tradera/plugins/actions/users/models/follow"
)

func searchPost(t *testing.T, s *Service, ctx context.Context, author, space identity.ID, body string, at time.Time) identity.ID {
	t.Helper()
	id, _ := identity.New(1)
	if err := s.R.CreateID(ctx, "posts", id, &post.Post{
		Entity: entity.Entity{ID: id, CreatedAt: at, UpdatedAt: at}, AuthorID: author, SpaceID: space, Body: body,
	}); err != nil {
		t.Fatal(err)
	}
	return id
}

// The Following search finds the posts of the authors the caller follows and
// of their spaces, newest first, and none of anyone else's.
func TestFollowingSearchCoversFollowsAndSpaces(t *testing.T) {
	s, ctx := feedHarness(t)
	me, _ := identity.New(1)
	followed, _ := identity.New(1)
	stranger, _ := identity.New(1)
	sp, _ := identity.New(1)
	fid, _ := identity.New(1)
	if err := s.R.CreateID(ctx, "follows", fid, &follow.Follow{
		Entity: entity.Entity{ID: fid, CreatedAt: time.Now()}, FollowerID: me, FolloweeID: followed,
	}); err != nil {
		t.Fatal(err)
	}
	mid, _ := identity.New(1)
	if err := s.R.CreateID(ctx, "memberships", mid, &membershipRow{SpaceID: sp.String(), MemberID: me.String()}); err != nil {
		t.Fatal(err)
	}
	base := time.Now().UTC()
	older := searchPost(t, s, ctx, followed, identity.ID{}, "BTC breakout watch", base.Add(-time.Hour))
	inSpace := searchPost(t, s, ctx, stranger, sp, "btc levels for the desk", base)
	searchPost(t, s, ctx, stranger, identity.ID{}, "BTC from a stranger", base)
	searchPost(t, s, ctx, followed, identity.ID{}, "ETH only", base)

	found, err := s.FollowingSearch(ctx, me, "btc", 20, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(found) != 2 || found[0].ID != inSpace || found[1].ID != older {
		t.Fatalf("found %v", found)
	}
	page, err := s.FollowingSearch(ctx, me, "btc", 1, 1)
	if err != nil || len(page) != 1 || page[0].ID != older {
		t.Fatalf("second page: %v %v", page, err)
	}
	feed, err := s.Feed(ctx, me, identity.ID{}, true, 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(feed) != 2 {
		t.Fatalf("the following feed holds the followed author's posts: %v", feed)
	}
}
