package posts

import (
	"fmt"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
)

func importItems(from, to int) []ImportItem {
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	var items []ImportItem
	for i := from; i < to; i++ {
		items = append(items, ImportItem{Source: "coinmarketcap", SourceID: fmt.Sprint(i),
			Body: fmt.Sprintf("cmc post %d", i), At: base.Add(time.Duration(i) * time.Hour).Format(time.RFC3339)})
	}
	return items
}

func TestImportPublishesEachSourcePostOnceAndNeverChangesIt(t *testing.T) {
	s, ctx := feedHarness(t)
	trader, _ := identity.New(1)
	first, err := s.Import(ctx, trader, importItems(0, 3))
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range first {
		if !r.Created || r.PostID == "" {
			t.Fatalf("new posts are published: %+v", r)
		}
	}
	again := importItems(0, 4)
	again[0].Body = "edited at the source"
	second, err := s.Import(ctx, trader, again)
	if err != nil {
		t.Fatal(err)
	}
	for i, r := range second[:3] {
		if r.Created || r.PostID != first[i].PostID {
			t.Fatalf("an imported post is left as it is: %+v", r)
		}
	}
	if !second[3].Created {
		t.Fatal("the new one is published")
	}
	p, err := s.Get(ctx, identity.MustParse(first[0].PostID))
	if err != nil || p.Body != "cmc post 0" {
		t.Fatalf("the existing post was overridden: %v %q", err, p.Body)
	}
}

func TestGlobalFeedShowsTradersLatestImportedPostsFirst(t *testing.T) {
	s, ctx := feedHarness(t)
	trader, _ := identity.New(1)
	someone, _ := identity.New(1)
	if _, err := s.Import(ctx, trader, importItems(0, 12)); err != nil {
		t.Fatal(err)
	}
	// Posts made here afterwards are newer, yet come after the featured ones.
	for i := 0; i < 5; i++ {
		if _, err := s.Create(ctx, someone, identity.ID{}, identity.ID{}, fmt.Sprintf("local %d", i), nil, nil); err != nil {
			t.Fatal(err)
		}
	}
	feed, err := s.Feed(ctx, someone, identity.ID{}, false, 50, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(feed) != 17 {
		t.Fatalf("every post is in the feed once: %d", len(feed))
	}
	for i := 0; i < FeaturedPerAuthor; i++ {
		want := fmt.Sprintf("cmc post %d", 11-i)
		if feed[i].Body != want {
			t.Fatalf("feed[%d] = %q, want %q (the trader's latest %d first, newest first)", i, feed[i].Body, want, FeaturedPerAuthor)
		}
	}
	// Paging walks the same order without repeats or gaps.
	seen := map[string]bool{}
	for offset := 0; offset < 17; offset += 4 {
		page, err := s.Feed(ctx, someone, identity.ID{}, false, 4, offset)
		if err != nil {
			t.Fatal(err)
		}
		for i, p := range page {
			if seen[p.ID.String()] || p.ID != feed[offset+i].ID {
				t.Fatalf("page at %d differs from the full feed at %d", offset, offset+i)
			}
			seen[p.ID.String()] = true
		}
	}
	if len(seen) != 17 {
		t.Fatalf("paging showed %d posts", len(seen))
	}
}

func TestImportedMediaAreImagesOrVideos(t *testing.T) {
	s, ctx := feedHarness(t)
	trader, _ := identity.New(1)
	item := importItems(0, 1)[0]
	item.Media = []ImportMedia{{Name: "a.html", Mime: "text/html", Data: []byte("<html>")}}
	res, err := s.Import(ctx, trader, []ImportItem{item})
	if err != nil {
		t.Fatal(err)
	}
	if res[0].Created || res[0].Error == "" {
		t.Fatalf("a post whose media are not images or videos is not published: %+v", res[0])
	}
	item.Media = make([]ImportMedia, maxImportMedia+1)
	if res, _ := s.Import(ctx, trader, []ImportItem{item}); res[0].Created {
		t.Fatal("too many media are refused")
	}
	feed, _ := s.Feed(ctx, trader, identity.ID{}, false, 10, 0)
	if len(feed) != 0 {
		t.Fatalf("nothing was published: %d", len(feed))
	}
}
