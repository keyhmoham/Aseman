package users

import (
	"bytes"
	"context"
	"io"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/mediahost"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// FetchURL downloads a remote medium; tests replace it.
var FetchURL = mediahost.DefaultFetch

// IngestURL downloads [rawURL] into the caller's public file store, or returns
// a cached public file already hosted from that address. Viewers load it from
// Aseman (`/v1/files/{id}/content`), never from the original host.
func (s *Service) IngestURL(ctx context.Context, owner identity.ID, rawURL string) (*filedata.File, bool, error) {
	key, err := mediahost.NormalizeURL(rawURL)
	if err != nil {
		return nil, false, err
	}
	if cached := s.cachedBySource(ctx, key); cached != nil {
		return cached, true, nil
	}
	name, mime, data, err := FetchURL(ctx, key)
	if err != nil {
		return nil, false, err
	}
	hash := mediahost.Hash(data)
	// Same bytes already stored under another URL still reuse the copy.
	if byHash := s.cachedByHash(ctx, hash); byHash != nil {
		if byHash.SourceURL == "" {
			byHash.SourceURL = key
			_ = s.R.Update(ctx, "files", byHash.ID, byHash)
		}
		return byHash, true, nil
	}
	file, err := s.UploadFile(ctx, owner, name, mime, int64(len(data)),
		io.NopCloser(bytes.NewReader(data)), "")
	if err != nil {
		return nil, false, err
	}
	file.Public = true
	file.SourceURL = key
	file.ContentHash = hash
	if err := s.R.Update(ctx, "files", file.ID, file); err != nil {
		return nil, false, err
	}
	return file, false, nil
}

func (s *Service) cachedBySource(ctx context.Context, sourceURL string) *filedata.File {
	var list []filedata.File
	if err := s.R.List(ctx, "files", database.Filter{
		Equal: map[string]any{"source_url": sourceURL, "public": true},
		Limit: 1,
	}, &list); err != nil || len(list) == 0 {
		return nil
	}
	return &list[0]
}

func (s *Service) cachedByHash(ctx context.Context, hash string) *filedata.File {
	if hash == "" {
		return nil
	}
	var list []filedata.File
	if err := s.R.List(ctx, "files", database.Filter{
		Equal: map[string]any{"content_hash": hash, "public": true},
		Limit: 1,
	}, &list); err != nil || len(list) == 0 {
		return nil
	}
	return &list[0]
}

// HostMarkupResult is a body whose remote media now point at stored files.
type HostMarkupResult struct {
	Body    string   `json:"body"`
	FileIDs []string `json:"file_ids,omitempty"`
	Cached  int      `json:"cached,omitempty"`
	Fetched int      `json:"fetched,omitempty"`
}

// HostMarkup downloads every remote image/video/audio in post/message markup
// into public storage (reusing the cache) and rewrites the body so clients
// only request Aseman file URLs.
func (s *Service) HostMarkup(ctx context.Context, owner identity.ID, body string) (*HostMarkupResult, error) {
	urls := mediahost.ExternalURLs(body)
	if len(urls) == 0 {
		return &HostMarkupResult{Body: body}, nil
	}
	refs := make(map[string]string, len(urls))
	ids := make([]string, 0, len(urls))
	var cached, fetched int
	for _, u := range urls {
		file, hit, err := s.IngestURL(ctx, owner, u)
		if err != nil {
			return nil, err
		}
		if hit {
			cached++
		} else {
			fetched++
		}
		ref := mediahost.ContentPath(file.ID.String())
		refs[u] = ref
		ids = append(ids, file.ID.String())
	}
	return &HostMarkupResult{
		Body:    mediahost.Rewrite(body, refs),
		FileIDs: ids,
		Cached:  cached,
		Fetched: fetched,
	}, nil
}

// fileIngestAction users.file_ingest — download one remote medium into storage.
type fileIngestAction struct{ s *Service }

func (a *fileIngestAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "file_ingest",
		Summary: "Download a remote image, video or audio into Aseman storage (cached by URL)"}
}
func (a *fileIngestAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		URL string `json:"url"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	file, cached, err := a.s.IngestURL(ctx, req.Caller.ID, in.URL)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{
		"file_id":     file.ID.String(),
		"name":        file.Name,
		"mime":        file.Mime,
		"size":        file.Size,
		"public":      file.Public,
		"content_url": mediahost.ContentPath(file.ID.String()),
		"source_url":  file.SourceURL,
		"cached":      cached,
	})
}

// hostMarkupAction users.host_markup — rewrite a post/message body's media.
type hostMarkupAction struct{ s *Service }

func (a *hostMarkupAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "host_markup",
		Summary: "Host every remote image/video/audio in markup on Aseman and rewrite the body"}
}
func (a *hostMarkupAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Body string `json:"body"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	res, err := a.s.HostMarkup(ctx, req.Caller.ID, in.Body)
	if err != nil {
		return nil, err
	}
	return helper.JSON(res)
}
