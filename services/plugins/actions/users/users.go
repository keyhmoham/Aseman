// Package users implements the users namespace: account management, metadata
// (JSON tree) management with public/private paths, files attached to metadata,
// and direct messaging.
package users

import (
	"bytes"
	"context"
	"io"
	"sort"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/jsonpatch"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	"github.com/tradera/tradera/plugins/actions/spaces/models/filedata"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/metasvc"
	"github.com/tradera/tradera/plugins/actions/support/models/metadata"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
)

// Service holds users dependencies.
type Service struct {
	K api.Kernel
	R *repo.Repo
	M *metasvc.Service
	L *logger.Logger
}

// Actions returns the users namespace actions.
func Actions(k api.Kernel, r *repo.Repo, log *logger.Logger) []api.Action {
	return BuildActions(&Service{K: k, R: r, M: &metasvc.Service{K: k, R: r}, L: log.Named("users")})
}

func BuildActions(s *Service) []api.Action {
	return append([]api.Action{
		&accountGetAction{s: s},
		&searchAction{s: s},
		&followAction{s: s},
		&unfollowAction{s: s},
		&followingListAction{s: s},
		&followersListAction{s: s},
		&metadataViewAction{s: s},
		&metadataPatchAction{s: s},
		&metadataReplaceAction{s: s},
		&metadataPublicAction{s: s},
		&dmSendAction{s: s},
		&dmListAction{s: s},
		&dmThreadsAction{s: s},
		&fileUploadAction{s: s},
		&fileDownloadAction{s: s},
		&fileDeleteAction{s: s},
	}, append(accountActions(s), pushActions(s)...)...)
}

// GetAccount resolves an account by universal id or handle.
func (s *Service) GetAccount(ctx context.Context, ref string) (*account.Account, error) {
	if id, err := identity.Parse(ref); err == nil {
		acc := &account.Account{}
		if err := s.R.Get(ctx, "accounts", id, acc); err == nil {
			return acc, nil
		}
	}
	var list []account.Account
	if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"handle": ref}}, &list); err == nil && len(list) > 0 {
		return &list[0], nil
	}
	return nil, errs.NotFound("account " + ref)
}

// UploadFile stores bytes in the filesystem and records the file row.
func (s *Service) UploadFile(ctx context.Context, owner identity.ID, name, mime string, size int64, r io.Reader, metaPath string) (*filedata.File, error) {
	fs := s.K.FS()
	if fs == nil {
		return nil, errs.New(errs.CodeUnavailable, "no filesystem adapter active")
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	key := id.String()
	if err := fs.Put(ctx, key, r, size, mime); err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	file := &filedata.File{
		Entity:     entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		OwnerID:    owner,
		Name:       name,
		Mime:       mime,
		Size:       size,
		StorageKey: key,
		MetaPath:   metaPath,
	}
	if err := s.R.CreateID(ctx, "files", id, file); err != nil {
		return nil, err
	}
	if metaPath != "" {
		_ = s.M.LinkFile(ctx, owner, metaPath, id)
	}
	return file, nil
}

// DownloadFile streams a file's bytes.
func (s *Service) DownloadFile(ctx context.Context, id identity.ID) (*filedata.File, io.ReadCloser, error) {
	fs := s.K.FS()
	if fs == nil {
		return nil, nil, errs.New(errs.CodeUnavailable, "no filesystem adapter active")
	}
	file := &filedata.File{}
	if err := s.R.Get(ctx, "files", id, file); err != nil {
		return nil, nil, err
	}
	rc, err := fs.Get(ctx, file.StorageKey)
	if err != nil {
		return nil, nil, err
	}
	return file, rc, nil
}

// accountGetAction users.account_get
type accountGetAction struct{ s *Service }

func (a *accountGetAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "account_get", Summary: "Public account profile"}
}
func (a *accountGetAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Account string `json:"account"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if resp, ok, err := helper.ProxyIfRemote(ctx, a.s.K, in.Account, "users", "account_get", req); ok {
		return resp, err
	}
	acc, err := a.s.GetAccount(ctx, in.Account)
	if err != nil {
		return nil, err
	}
	// Profile metadata (display name, bio, avatar, ...) from the account's
	// metadata tree (public paths only).
	profile := map[string]any{}
	if rec, merr := a.s.M.View(ctx, req.Caller.ID, acc.ID); merr == nil && rec != nil {
		if t, ok := rec.Tree["profile"].(map[string]any); ok {
			profile = t
		}
	}
	// Follow relationship + counts.
	followers, following, err := a.s.FollowCounts(ctx, acc.ID)
	if err != nil {
		return nil, err
	}
	amFollowing := false
	if !req.Caller.ID.IsZero() {
		amFollowing, _ = a.s.IsFollowing(ctx, req.Caller.ID, acc.ID)
	}
	return helper.JSON(map[string]any{
		"id": acc.ID.String(), "handle": acc.Handle, "kind": acc.Kind,
		"status": acc.Status, "metadata_id": acc.MetadataID.String(),
		"profile":   profile,
		"followers": followers, "following": following,
		"am_following": amFollowing,
	})
}

// searchAction implements users.search: find accounts by handle/email.
type searchAction struct{ s *Service }

func (a *searchAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "search", Summary: "Search accounts by handle or email"}
}
func (a *searchAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
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
	var list []account.Account
	if err := a.s.R.List(ctx, "accounts", database.Filter{}, &list); err != nil {
		return nil, err
	}
	q := strings.ToLower(strings.TrimSpace(in.Query))
	var out []map[string]any
	for _, acc := range list {
		if q == "" || strings.Contains(strings.ToLower(acc.Handle), q) ||
			strings.Contains(strings.ToLower(acc.Email), q) {
			out = append(out, a.s.publicRef(ctx, req.Caller.ID, acc.ID))
		}
	}
	start := offset
	if start > len(out) {
		start = len(out)
	}
	end := len(out)
	if limit > 0 && start+limit < end {
		end = start + limit
	}
	return helper.JSON(map[string]any{"users": out[start:end]})
}

// metadataViewAction users.metadata_view
type metadataViewAction struct{ s *Service }

func (a *metadataViewAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "metadata_view", Summary: "View an account metadata tree (visibility filtered)"}
}
func (a *metadataViewAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Account string `json:"account"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if resp, ok, err := helper.ProxyIfRemote(ctx, a.s.K, in.Account, "users", "metadata_view", req); ok {
		return resp, err
	}
	acc, err := a.s.GetAccount(ctx, in.Account)
	if err != nil {
		return nil, err
	}
	viewer := req.Caller.ID
	rec, err := a.s.M.View(ctx, viewer, acc.ID)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{
		"owner": rec.Owner, "tree": rec.Tree, "public_paths": rec.PublicPaths, "version": rec.Version,
	})
}

// metadataPatchAction users.metadata_patch
type metadataPatchAction struct{ s *Service }

func (a *metadataPatchAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "metadata_patch", Summary: "Patch own metadata tree (add/set/remove ops)"}
}
func (a *metadataPatchAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Patch jsonpatch.Patch `json:"patch"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if err := a.s.M.Patch(ctx, req.Caller.ID, in.Patch); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

// metadataReplaceAction users.metadata_replace
type metadataReplaceAction struct{ s *Service }

func (a *metadataReplaceAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "metadata_replace", Summary: "Replace the whole metadata tree"}
}
func (a *metadataReplaceAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Tree metadata.Tree `json:"tree"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if err := a.s.M.ReplaceTree(ctx, req.Caller.ID, in.Tree); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

// metadataPublicAction users.metadata_public
type metadataPublicAction struct{ s *Service }

func (a *metadataPublicAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "metadata_public", Summary: "Set which metadata paths are public"}
}
func (a *metadataPublicAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Paths []string `json:"paths"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if err := a.s.M.SetPublicPaths(ctx, req.Caller.ID, in.Paths); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "paths": jsonpatch.Paths(in.Paths).Normalize()})
}

// dmSendAction users.dm_send
type dmSendAction struct{ s *Service }

func (a *dmSendAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "dm_send", Summary: "Send a direct message to a user or bot"}
}
func (a *dmSendAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		To   string `json:"to"`
		Body string `json:"body"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if in.Body == "" {
		return nil, errs.InvalidArgument("body required")
	}
	if resp, ok, err := helper.ProxyIfRemote(ctx, a.s.K, in.To, "users", "dm_send", req); ok {
		return resp, err
	}
	to, err := identity.Parse(in.To)
	if err != nil {
		return nil, err
	}
	id, err := identity.New(a.s.K.NodeID())
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	dm := &message.Direct{
		Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		From:   req.Caller.ID, To: to, Body: in.Body, SentAt: now,
	}
	if err := a.s.R.CreateID(ctx, "directs", id, dm); err != nil {
		return nil, err
	}
	// A message to an agent is a conversation with it: the agent answers in
	// the same direct thread, without holding up this request. An agent
	// messaging another agent inside a run keeps that run's scope.
	if botID, ok := a.s.agentAccount(ctx, to); ok && to != req.Caller.ID {
		go a.s.deliverDirect(helper.WithActor(context.WithoutCancel(ctx), req.Caller.ID), req.Caller.ID, to, botID, in.Body)
	}
	return helper.JSON(map[string]any{"id": id.String(), "ok": true})
}

// dmListAction users.dm_list
type dmListAction struct{ s *Service }

func (a *dmListAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "dm_list", Summary: "List direct messages with a peer"}
}
func (a *dmListAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Peer  string `json:"peer"`
		Limit int    `json:"limit"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	peer, err := identity.Parse(in.Peer)
	if err != nil {
		return nil, err
	}
	if in.Limit <= 0 || in.Limit > 200 {
		in.Limit = 50
	}
	// The newest messages of the conversation, in both directions, returned
	// oldest first so a client renders them top to bottom.
	var mine, theirs []message.Direct
	if err := a.s.R.List(ctx, "directs", database.Filter{
		Equal:   map[string]any{"from_id": req.Caller.ID.String(), "to_id": peer.String()},
		OrderBy: "created_at", Asc: false, Limit: in.Limit,
	}, &mine); err != nil {
		return nil, err
	}
	if err := a.s.R.List(ctx, "directs", database.Filter{
		Equal:   map[string]any{"from_id": peer.String(), "to_id": req.Caller.ID.String()},
		OrderBy: "created_at", Asc: false, Limit: in.Limit,
	}, &theirs); err != nil {
		return nil, err
	}
	out := append(mine, theirs...)
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	if len(out) > in.Limit {
		out = out[:in.Limit]
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return helper.JSON(map[string]any{"messages": out})
}

// dmThreadsAction users.dm_threads: the caller's conversations, newest first,
// each with the peer's public identity and the latest message.
type dmThreadsAction struct{ s *Service }

func (a *dmThreadsAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "dm_threads", Summary: "List my direct message conversations"}
}
func (a *dmThreadsAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Limit int `json:"limit,omitempty"`
	}
	_ = helper.Decode(req, &in)
	if in.Limit <= 0 || in.Limit > 100 {
		in.Limit = 50
	}
	var sent, received []message.Direct
	if err := a.s.R.List(ctx, "directs", database.Filter{Equal: map[string]any{"from_id": req.Caller.ID.String()}, OrderBy: "created_at", Asc: false, Limit: 1000}, &sent); err != nil {
		return nil, err
	}
	if err := a.s.R.List(ctx, "directs", database.Filter{Equal: map[string]any{"to_id": req.Caller.ID.String()}, OrderBy: "created_at", Asc: false, Limit: 1000}, &received); err != nil {
		return nil, err
	}
	all := append(sent, received...)
	sort.Slice(all, func(i, j int) bool { return all[i].CreatedAt.After(all[j].CreatedAt) })
	threads := []map[string]any{}
	seen := map[string]bool{}
	for _, dm := range all {
		peer := dm.To
		if dm.To == req.Caller.ID {
			peer = dm.From
		}
		if seen[peer.String()] {
			continue
		}
		seen[peer.String()] = true
		threads = append(threads, map[string]any{"peer": a.s.publicRef(ctx, req.Caller.ID, peer), "last": dm})
		if len(threads) >= in.Limit {
			break
		}
	}
	return helper.JSON(map[string]any{"threads": threads})
}

// fileUploadAction users.file_upload
type fileUploadAction struct{ s *Service }

func (a *fileUploadAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "file_upload", Summary: "Upload a file and link it to a metadata path"}
}
func (a *fileUploadAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Name     string `json:"name"`
		Mime     string `json:"mime"`
		MetaPath string `json:"meta_path"`
		Data     []byte `json:"data"` // base64 encoded by transport
		Public   bool   `json:"public,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if in.Name == "" || len(in.Data) == 0 {
		return nil, errs.InvalidArgument("name and data required")
	}
	if in.Mime == "" {
		in.Mime = "application/octet-stream"
	}
	file, err := a.s.UploadFile(ctx, req.Caller.ID, in.Name, in.Mime, int64(len(in.Data)),
		bytes.NewReader(in.Data), in.MetaPath)
	if err != nil {
		return nil, err
	}
	if in.Public {
		file.Public = true
		if e := a.s.R.Update(ctx, "files", file.ID, file); e != nil {
			return nil, e
		}
	}
	return helper.JSON(map[string]any{"file_id": file.ID.String(), "size": file.Size})
}

// fileDownloadAction users.file_download
type fileDownloadAction struct{ s *Service }

func (a *fileDownloadAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "file_download", Summary: "Download a file"}
}
func (a *fileDownloadAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		File string `json:"file"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.File)
	if err != nil {
		return nil, err
	}
	file, rc, err := a.s.DownloadFile(ctx, id)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	data, err := io.ReadAll(rc)
	if err != nil {
		return nil, errs.Wrap(errs.CodeInternal, err, "read file")
	}
	return helper.JSON(map[string]any{
		"file_id": file.ID.String(), "name": file.Name, "mime": file.Mime,
		"size": file.Size, "data": data,
	})
}

// fileDeleteAction users.file_delete
type fileDeleteAction struct{ s *Service }

func (a *fileDeleteAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "users", Name: "file_delete", Summary: "Delete an owned file"}
}
func (a *fileDeleteAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		File string `json:"file"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.File)
	if err != nil {
		return nil, err
	}
	file := &filedata.File{}
	if err := a.s.R.Get(ctx, "files", id, file); err != nil {
		return nil, err
	}
	if file.OwnerID != req.Caller.ID {
		return nil, errs.Permission("not the file owner")
	}
	if fs := a.s.K.FS(); fs != nil {
		_ = fs.Delete(ctx, file.StorageKey)
	}
	if err := a.s.R.Delete(ctx, "files", id); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}
