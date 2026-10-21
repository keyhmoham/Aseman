package posts

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/kernel"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/posts/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/database/memory"
	dbmodel "github.com/aseman/aseman/plugins/testutil"
)

func feedHarness(t *testing.T) (*Service, context.Context) {
	t.Helper()
	ad := memory.New(logger.Global())
	ctx := context.Background()
	for _, m := range dbmodel.Models() {
		if err := ad.RegisterModel(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	k := kernel.New(kernel.Options{NodeID: 1, Logger: logger.Global()})
	r := &repo.Repo{DB: ad}
	return NewService(k, r, logger.Global()), ctx
}

// TestFeedShowsNewestFirst proves that the global feed returns every post and
// orders them newest-first (a broken created_at sort used to push new posts
// past the limit so they never appeared).
func TestFeedShowsNewestFirst(t *testing.T) {
	s, ctx := feedHarness(t)
	author, _ := identity.New(1)
	base := time.Now().UTC()
	for i := 0; i < 25; i++ {
		id, _ := identity.New(1)
		now := base.Add(time.Duration(i) * time.Minute)
		p := &post.Post{
			Entity:   entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
			AuthorID: author,
			Body:     fmt.Sprintf("post %d", i),
		}
		if err := s.R.CreateID(ctx, "posts", id, p); err != nil {
			t.Fatal(err)
		}
	}

	feed, err := s.Feed(ctx, author, identity.ID{}, false, 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(feed) != 25 {
		t.Fatalf("global feed: expected 25 posts, got %d", len(feed))
	}
	for i := 1; i < len(feed); i++ {
		if feed[i].CreatedAt.After(feed[i-1].CreatedAt) {
			t.Fatalf("feed not newest-first at index %d", i)
		}
	}
	if !feed[0].CreatedAt.Equal(base.Add(24 * time.Minute)) {
		t.Fatalf("newest post must be first, got %v", feed[0].CreatedAt)
	}
}

// TestFeedLimitKeepsNewest proves a limit returns the newest posts, not the
// oldest (the failure mode that hid freshly created posts).
func TestFeedLimitKeepsNewest(t *testing.T) {
	s, ctx := feedHarness(t)
	author, _ := identity.New(1)
	base := time.Now().UTC()
	for i := 0; i < 25; i++ {
		id, _ := identity.New(1)
		now := base.Add(time.Duration(i) * time.Minute)
		p := &post.Post{
			Entity:   entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
			AuthorID: author,
			Body:     fmt.Sprintf("post %d", i),
		}
		if err := s.R.CreateID(ctx, "posts", id, p); err != nil {
			t.Fatal(err)
		}
	}

	feed, err := s.Feed(ctx, author, identity.ID{}, false, 10, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(feed) != 10 {
		t.Fatalf("expected 10 posts, got %d", len(feed))
	}
	if !feed[0].CreatedAt.Equal(base.Add(24 * time.Minute)) {
		t.Fatalf("limit must return newest first, got %v", feed[0].CreatedAt)
	}
}

// TestCreateThenGlobalFeed proves posts created through the service are
// returned by the global feed (the user-reported flow).
func TestCreateThenGlobalFeed(t *testing.T) {
	s, ctx := feedHarness(t)
	author, _ := identity.New(1)

	for i := 0; i < 2; i++ {
		if _, err := s.Create(ctx, author, identity.ID{}, identity.ID{}, fmt.Sprintf("hello %d", i), nil, nil); err != nil {
			t.Fatal(err)
		}
	}

	feed, err := s.Feed(ctx, author, identity.ID{}, false, 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(feed) != 2 {
		t.Fatalf("expected the 2 created posts in the global feed, got %d", len(feed))
	}
}

// TestGlobalFeedExcludesWorkspacePosts proves private workspace posts never
// leak into the global feed.
func TestGlobalFeedExcludesWorkspacePosts(t *testing.T) {
	s, ctx := feedHarness(t)
	author, _ := identity.New(1)
	spaceID, _ := identity.New(1)

	gid, _ := identity.New(1)
	if err := s.R.CreateID(ctx, "posts", gid, &post.Post{
		Entity: entity.Entity{ID: gid, CreatedAt: time.Now().Add(-time.Minute)}, AuthorID: author, Body: "global",
	}); err != nil {
		t.Fatal(err)
	}
	wid, _ := identity.New(1)
	if err := s.R.CreateID(ctx, "posts", wid, &post.Post{
		Entity: entity.Entity{ID: wid, CreatedAt: time.Now()}, AuthorID: author, SpaceID: spaceID, Body: "private",
	}); err != nil {
		t.Fatal(err)
	}

	feed, err := s.Feed(ctx, author, identity.ID{}, false, 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range feed {
		if p.SpaceID == spaceID {
			t.Fatalf("workspace post leaked into the global feed: %s", p.Body)
		}
	}
}

// TestSpaceFeedRequiresMembership proves a space-scoped feed is private.
func TestSpaceFeedRequiresMembership(t *testing.T) {
	s, ctx := feedHarness(t)
	author, _ := identity.New(1)
	spaceID, _ := identity.New(1)

	if _, err := s.Feed(ctx, author, spaceID, false, 50, 0); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("expected permission error for non-member, got %v", err)
	}

	memID, _ := identity.New(1)
	if err := s.R.CreateID(ctx, "memberships", memID, &membershipRow{
		SpaceID: spaceID.String(), MemberID: author.String(),
	}); err != nil {
		t.Fatal(err)
	}
	pid, _ := identity.New(1)
	if err := s.R.CreateID(ctx, "posts", pid, &post.Post{
		Entity: entity.Entity{ID: pid, CreatedAt: time.Now()}, AuthorID: author, SpaceID: spaceID, Body: "private",
	}); err != nil {
		t.Fatal(err)
	}
	feed, err := s.Feed(ctx, author, spaceID, false, 50, 0)
	if err != nil {
		t.Fatalf("member should read the space feed: %v", err)
	}
	if len(feed) != 1 {
		t.Fatalf("expected 1 workspace post, got %d", len(feed))
	}
}

// TestSpacesFeedAggregates proves the spaces feed unions the private posts of
// every workspace the caller belongs to.
func TestSpacesFeedAggregates(t *testing.T) {
	s, ctx := feedHarness(t)
	author, _ := identity.New(1)
	sp1, _ := identity.New(1)
	sp2, _ := identity.New(1)

	for _, sp := range []identity.ID{sp1, sp2} {
		mid, _ := identity.New(1)
		if err := s.R.CreateID(ctx, "memberships", mid, &membershipRow{
			SpaceID: sp.String(), MemberID: author.String(),
		}); err != nil {
			t.Fatal(err)
		}
		pid, _ := identity.New(1)
		if err := s.R.CreateID(ctx, "posts", pid, &post.Post{
			Entity: entity.Entity{ID: pid, CreatedAt: time.Now()}, AuthorID: author, SpaceID: sp, Body: "in workspace",
		}); err != nil {
			t.Fatal(err)
		}
	}
	// A global post must not appear in the spaces feed.
	gid, _ := identity.New(1)
	if err := s.R.CreateID(ctx, "posts", gid, &post.Post{
		Entity: entity.Entity{ID: gid, CreatedAt: time.Now()}, AuthorID: author, Body: "global",
	}); err != nil {
		t.Fatal(err)
	}

	feed, err := s.SpacesFeed(ctx, author, 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(feed) != 2 {
		t.Fatalf("expected 2 workspace posts aggregated, got %d", len(feed))
	}
	for _, p := range feed {
		if p.SpaceID.IsZero() {
			t.Fatalf("global post leaked into the spaces feed")
		}
	}
}

// TestViewsHideWorkspacePostsFromNonMembers proves a workspace post is only
// rendered for members, and that views carry author, like and comment state.
func TestViewsHideWorkspacePostsFromNonMembers(t *testing.T) {
	s, ctx := feedHarness(t)
	author, _ := identity.New(1)
	outsider, _ := identity.New(1)
	space, _ := identity.New(1)
	memID, _ := identity.New(1)
	now := time.Now().UTC()
	if err := s.R.CreateID(ctx, "memberships", memID, &struct {
		entity.Entity
		SpaceID  identity.ID `db:"space_id"`
		RoomID   identity.ID `db:"room_id"`
		MemberID identity.ID `db:"member_id"`
		Role     string      `db:"role"`
	}{Entity: entity.Entity{ID: memID, CreatedAt: now, UpdatedAt: now}, SpaceID: space, MemberID: author, Role: "owner"}); err != nil {
		t.Fatal(err)
	}
	public, err := s.Create(ctx, author, identity.ID{}, identity.ID{}, "hello world", []string{"intro"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	private, err := s.Create(ctx, author, space, identity.ID{}, "team only", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Like(ctx, outsider, public.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Comment(ctx, outsider, public.ID, "nice"); err != nil {
		t.Fatal(err)
	}
	list, err := s.UserPosts(ctx, author, 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	seen := s.Views(ctx, outsider, list)
	if len(seen) != 1 || seen[0]["id"] != public.ID.String() {
		t.Fatalf("outsider must only see the public post: %+v", seen)
	}
	if seen[0]["liked"] != true || seen[0]["comments"] != int64(1) || len(seen[0]["tags"].([]string)) != 1 {
		t.Fatalf("view state wrong: %+v", seen[0])
	}
	if got := s.Views(ctx, author, list); len(got) != 2 {
		t.Fatalf("a member sees the workspace post too: %+v", got)
	}
	if err := s.Like(ctx, outsider, private.ID); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("outsider must not like a workspace post: %v", err)
	}
	if _, err := s.Comment(ctx, outsider, private.ID, "x"); errs.CodeOf(err) != errs.CodePermission {
		t.Fatalf("outsider must not comment on a workspace post: %v", err)
	}
}
