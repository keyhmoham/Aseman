package users

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	"github.com/aseman/aseman/plugins/actions/support/mediahost"
)

func TestIngestURLReusesCachedSource(t *testing.T) {
	s, ctx := followHarness(t)
	owner := mustID(t, "00000000000000010000000000000001")
	src := "https://cdn.example/photo.png"
	key, err := mediahost.NormalizeURL(src)
	if err != nil {
		t.Fatal(err)
	}
	id, _ := identity.New(1)
	now := time.Now().UTC()
	existing := &filedata.File{
		Entity:      entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		OwnerID:     owner,
		Name:        "photo.png",
		Mime:        "image/png",
		Size:        4,
		StorageKey:  "users/" + owner.String() + "/" + id.String(),
		Public:      true,
		SourceURL:   key,
		ContentHash: mediahost.Hash([]byte("png!")),
	}
	if err := s.R.CreateID(ctx, "files", id, existing); err != nil {
		t.Fatal(err)
	}
	FetchURL = func(context.Context, string) (string, string, []byte, error) {
		t.Fatal("cache hit must not download again")
		return "", "", nil, nil
	}
	t.Cleanup(func() { FetchURL = mediahost.DefaultFetch })

	got, cached, err := s.IngestURL(ctx, owner, "HTTPS://CDN.Example/photo.png")
	if err != nil || !cached || got.ID != id {
		t.Fatalf("cache: file=%v cached=%v err=%v", got, cached, err)
	}
}

func TestHostMarkupRewritesRemoteMedia(t *testing.T) {
	s, ctx := followHarness(t)
	owner := mustID(t, "00000000000000010000000000000001")
	src := "https://cdn.example/a.png"
	key, _ := mediahost.NormalizeURL(src)
	id, _ := identity.New(1)
	now := time.Now().UTC()
	if err := s.R.CreateID(ctx, "files", id, &filedata.File{
		Entity:    entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		OwnerID:   owner,
		Name:      "a.png",
		Mime:      "image/png",
		Size:      1,
		Public:    true,
		SourceURL: key,
	}); err != nil {
		t.Fatal(err)
	}
	FetchURL = func(context.Context, string) (string, string, []byte, error) {
		t.Fatal("should use cache")
		return "", "", nil, nil
	}
	t.Cleanup(func() { FetchURL = mediahost.DefaultFetch })

	body := "Hi\n\n:::image https://cdn.example/a.png\n"
	res, err := s.HostMarkup(ctx, owner, body)
	if err != nil {
		t.Fatal(err)
	}
	want := ":::image " + mediahost.ContentPath(id.String())
	if !strings.Contains(res.Body, want) || strings.Contains(res.Body, "https://cdn.example") {
		t.Fatalf("body:\n%s", res.Body)
	}
	if res.Cached != 1 || res.Fetched != 0 || len(res.FileIDs) != 1 {
		t.Fatalf("stats: %+v", res)
	}
}
