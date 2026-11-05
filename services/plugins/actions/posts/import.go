package posts

import (
	"bytes"
	"context"
	"io"
	"sort"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/posts/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Imported posts are the ones a person published somewhere else (their
// posts on another network) put on the person's account here. An import
// publishes each source post once, as a global post, and never edits or
// replaces it afterwards; the author's newest FeaturedPerAuthor imported
// posts are featured: the global feed shows them above every other post.

// FeaturedPerAuthor is how many of an author's imported posts are featured.
const FeaturedPerAuthor = 10

// maxFeatured bounds the featured block of the global feed.
const maxFeatured = 500

// maxImport bounds one import.
const maxImport = 50

// maxImportMedia and maxMediaBytes bound one imported post's media.
const (
	maxImportMedia = 9
	maxMediaBytes  = 25 << 20
)

// ImportMedia is an image, GIF or video of an imported post, stored as a
// public file of its author and attached to the post.
type ImportMedia struct {
	Name string `json:"name"`
	Mime string `json:"mime"`
	Data []byte `json:"data"` // base64 in JSON
}

// ImportItem is one post to import.
type ImportItem struct {
	Source   string   `json:"source"`
	SourceID string   `json:"source_id"`
	Body     string   `json:"body"`
	Tags     []string `json:"tags,omitempty"`
	// At is when it was published at its source (RFC 3339).
	At string `json:"at,omitempty"`
	// Media are attached when the post is published (never to one already
	// here).
	Media []ImportMedia `json:"media,omitempty"`
}

// ImportResult is what one item came to.
type ImportResult struct {
	SourceID string `json:"source_id"`
	PostID   string `json:"post_id,omitempty"`
	Created  bool   `json:"created"`
	// Media are the stored files attached to a post this import published.
	Media []string `json:"media,omitempty"`
	Error string   `json:"error,omitempty"`
}

// Import publishes, as author, each item not imported before (by source and
// source id); items already here are left exactly as they are. It then
// features the author's newest FeaturedPerAuthor imported posts.
func (s *Service) Import(ctx context.Context, author identity.ID, items []ImportItem) ([]ImportResult, error) {
	if len(items) > maxImport {
		return nil, errs.InvalidArgument("import at most 50 posts at a time")
	}
	out := make([]ImportResult, 0, len(items))
	for _, it := range items {
		it.Source, it.SourceID, it.Body = strings.TrimSpace(it.Source), strings.TrimSpace(it.SourceID), strings.TrimSpace(it.Body)
		res := ImportResult{SourceID: it.SourceID}
		if it.Source == "" || it.SourceID == "" {
			res.Error = "source and source_id are required"
			out = append(out, res)
			continue
		}
		var existing []post.Post
		if err := s.R.List(ctx, "posts", database.Filter{Equal: map[string]any{
			"author_id": author.String(), "source": it.Source, "source_id": it.SourceID,
		}, Limit: 1}, &existing); err != nil {
			return nil, err
		}
		if len(existing) > 0 {
			res.PostID = existing[0].ID.String()
			out = append(out, res)
			continue
		}
		media, err := s.storeMedia(ctx, author, it.Media)
		if err != nil {
			res.Error = err.Error()
			out = append(out, res)
			continue
		}
		p, err := s.Create(ctx, author, identity.ID{}, identity.ID{}, it.Body, it.Tags, media)
		if err != nil {
			res.Error = err.Error()
			out = append(out, res)
			continue
		}
		at, perr := time.Parse(time.RFC3339, strings.TrimSpace(it.At))
		if perr != nil {
			at = p.CreatedAt
		}
		p.Source, p.SourceID, p.SourceAt = it.Source, it.SourceID, at.UTC()
		if err := s.R.Update(ctx, "posts", p.ID, p); err != nil {
			return nil, err
		}
		res.PostID, res.Created, res.Media = p.ID.String(), true, media
		out = append(out, res)
	}
	return out, s.feature(ctx, author)
}

// storeMedia stores an imported post's media as public files of its author
// (everyone who sees the post sees them); their ids.
func (s *Service) storeMedia(ctx context.Context, author identity.ID, media []ImportMedia) ([]string, error) {
	if len(media) > maxImportMedia {
		return nil, errs.InvalidArgument("a post carries at most 9 media")
	}
	ids := make([]string, 0, len(media))
	for _, m := range media {
		mime := strings.ToLower(strings.TrimSpace(m.Mime))
		if !strings.HasPrefix(mime, "image/") && !strings.HasPrefix(mime, "video/") {
			return nil, errs.InvalidArgument("media are images or videos, not " + mime)
		}
		if len(m.Data) == 0 || len(m.Data) > maxMediaBytes {
			return nil, errs.InvalidArgument("a medium is 1 byte to 25 MB")
		}
		var file *filedata.File
		if err := bridge.Invoke(ctx, s.K, "users", "UploadFile", []any{ctx, author, strings.TrimSpace(m.Name), mime,
			int64(len(m.Data)), io.Reader(bytes.NewReader(m.Data)), ""}, &file); err != nil {
			return nil, err
		}
		if file == nil {
			return nil, errs.New(errs.CodeUnavailable, "the medium could not be stored")
		}
		file.Public = true
		if err := s.R.Update(ctx, "files", file.ID, file); err != nil {
			return nil, err
		}
		ids = append(ids, file.ID.String())
	}
	return ids, nil
}

// feature marks the author's newest FeaturedPerAuthor imported posts
// featured and the older ones not; only that flag changes.
func (s *Service) feature(ctx context.Context, author identity.ID) error {
	var imported []post.Post
	if err := s.R.List(ctx, "posts", database.Filter{
		Equal: map[string]any{"author_id": author.String(), "parent_id": zeroID, "space_id": zeroID},
	}, &imported); err != nil {
		return err
	}
	kept := imported[:0]
	for _, p := range imported {
		if p.Source != "" {
			kept = append(kept, p)
		}
	}
	imported = kept
	sort.SliceStable(imported, func(i, j int) bool { return imported[i].SourceAt.After(imported[j].SourceAt) })
	for i := range imported {
		p := &imported[i]
		want := int64(0)
		if i < FeaturedPerAuthor {
			want = 1
		}
		if p.Featured == want {
			continue
		}
		p.Featured = want
		if err := s.R.Update(ctx, "posts", p.ID, p); err != nil {
			return err
		}
	}
	return nil
}

// globalFeed lists the public top-level posts: the featured ones first
// (newest at their source first), then every other one newest first.
// Results are scoped to authors the caller may see across sub-platforms.
func (s *Service) globalFeed(ctx context.Context, caller identity.ID, limit, offset int) ([]post.Post, error) {
	// Over-fetch then filter by author tenancy so pages stay full when some
	// posts belong to isolated sub-platforms.
	fetch := (offset + limit) * 4
	if fetch < limit*2 {
		fetch = limit * 2
	}
	if fetch > 500 {
		fetch = 500
	}
	var featured []post.Post
	if err := s.R.List(ctx, "posts", database.Filter{
		Equal:   map[string]any{"parent_id": zeroID, "space_id": zeroID, "featured": int64(1)},
		OrderBy: "source_at", Limit: maxFeatured,
	}, &featured); err != nil {
		return nil, err
	}
	featured = s.filterPostsByAuthorTenancy(ctx, caller, featured)
	out := make([]post.Post, 0, limit)
	if offset < len(featured) {
		out = append(out, featured[offset:min(len(featured), offset+limit)]...)
	}
	need := limit - len(out)
	if need <= 0 {
		return out, nil
	}
	skip := max(0, offset-len(featured))
	shown := make(map[identity.ID]bool, len(featured))
	for _, p := range featured {
		shown[p.ID] = true
	}
	var rest []post.Post
	if err := s.R.List(ctx, "posts", database.Filter{
		Equal:   map[string]any{"parent_id": zeroID, "space_id": zeroID},
		OrderBy: "created_at", Limit: fetch + len(featured),
	}, &rest); err != nil {
		return nil, err
	}
	rest = s.filterPostsByAuthorTenancy(ctx, caller, rest)
	for _, p := range rest {
		if shown[p.ID] {
			continue
		}
		if skip > 0 {
			skip--
			continue
		}
		out = append(out, p)
		if len(out) == limit {
			break
		}
	}
	return out, nil
}

// postImportAction implements posts.post_import.
type postImportAction struct{ s *Service }

func (a *postImportAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "post_import",
		Summary: "Admin: publish a managed account's posts from another platform, each once (the admins space's tools, for an administrator)"}
}
func (a *postImportAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Author string       `json:"author"`
		Posts  []ImportItem `json:"posts"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	author, err := identity.Parse(in.Author)
	if err != nil {
		return nil, errs.InvalidArgument("invalid author id")
	}
	if err := bridge.Invoke(ctx, a.s.K, "users", "MayPublishFor", []any{ctx, req, author}); err != nil {
		return nil, err
	}
	results, err := a.s.Import(ctx, author, in.Posts)
	if err != nil {
		return nil, err
	}
	created, existing, failed := 0, 0, 0
	for _, r := range results {
		switch {
		case r.Error != "":
			failed++
		case r.Created:
			created++
		default:
			existing++
		}
	}
	return helper.JSON(map[string]any{"ok": true, "created": created, "existing": existing, "failed": failed, "posts": results})
}
