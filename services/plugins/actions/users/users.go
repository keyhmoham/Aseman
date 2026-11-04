// Package users implements the users namespace: account management, metadata
// (JSON tree) management with public/private paths, files attached to metadata,
// and direct messaging.
package users

import (
	"bytes"
	"context"
	"encoding/json"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
	"io"
	"sort"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/jsonpatch"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/metasvc"
	"github.com/aseman/aseman/plugins/actions/support/models/metadata"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Service holds users dependencies.
type Service struct {
	K api.Kernel
	R *repo.Repo
	M *metasvc.Service
	L *logger.Logger

	// FileAccess replaces the file server's rule (spaces.CanReadFile) in tests: whether the caller may read the file.
	FileAccess func(ctx context.Context, file, caller identity.ID) error

	// StorageLimit replaces the admin's Storage setting in tests: the most one person's files may use, in bytes (0 = none).
	StorageLimit func(ctx context.Context) int64

	// assistantFn and answerFn replace the bots namespace in tests: who the chat assistant is, and how it answers.
	// workFn and turnFn replace the spaces plugin in tests: starting work in the person's workspace, and how it stands.
	workFn func(ctx context.Context, me identity.ID, request string) (workStart, error)
	turnFn func(ctx context.Context, me identity.ID, turn string) (turnResult, error)

	// voiceActiveFn, speakFn, transcribeFn and voiceAnswerFn replace llm/bots/brain in tests.
	voiceActiveFn func(ctx context.Context) map[string]bool
	speakFn       func(ctx context.Context, me identity.ID, text string) (*vmm.Speech, error)
	transcribeFn  func(ctx context.Context, me identity.ID, audio []byte, mime string) (*vmm.Transcription, error)
	voiceAnswerFn func(ctx context.Context, me identity.ID, text string) (string, error)

	// webFn replaces fetching a web page (read_webpage) in tests.
	webFn func(ctx context.Context, address string) (string, error)

	assistantFn func(ctx context.Context) (*bot.Bot, error)
	answerFn    func(ctx context.Context, person identity.ID, rec *bot.Bot, turns []map[string]string, onText func(string)) (string, error)

	// The person's Aseman (brain.go) in tests: its memory, the decision model, its answers and the rooms it reads.
	memoryFn      func() vmm.PersonMemory
	decideFn      func(ctx context.Context, body string) brainPlan
	brainAnswerFn func(ctx context.Context, person identity.ID, rec *bot.Bot, brief string, turns []map[string]string, onText func(string)) (string, error)
	roomsFn       func(ctx context.Context, person identity.ID) ([]brainRoom, error)
	linesFn       func(ctx context.Context, person identity.ID, space string) []brainLine
	// What it does for the person (brain_tools.go) in tests: its answers with tools, and the actions it runs as them.
	actFn   func(ctx context.Context, person identity.ID, brief string, turns []map[string]string) (string, error)
	fundsFn func(ctx context.Context, person identity.ID) error
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
		&dmAgentAskAction{s: s},
		&dmAssistantAction{s: s},
		brainConfirmAction(s),
		brainWorkAction(s),
		adminAILogAction(s),
		voiceConfigAction(s),
		voiceSpeakAction(s),
		voiceTurnAction(s),
		brainRetryAction(s),
		&dmListAction{s: s},
		&dmThreadsAction{s: s},
		&fileUploadAction{s: s},
		&fileDownloadAction{s: s},
		&fileDeleteAction{s: s},
		&fileIngestAction{s: s},
		&hostMarkupAction{s: s},
	}, append(append(append(append(append(append(append(append(append(append(accountActions(s), pushActions(s)...), notificationActions(s)...), directActions(s)...), directLiveActions(s)...), reportActions(s)...), callActions(s)...), dmFileActions(s)...), notifyActions(s)...), privacyActions(s)...), brainActions(s)...)...)
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
	key := "users/" + owner.String() + "/" + id.String() // one folder per person in the object store
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
	return api.ActionMeta{Namespace: "users", Name: "search", Summary: "Search people (not agents or apps) by handle or email"}
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
	// Only people: agents and apps have accounts too, but they are found
	// through bots.bot_search.
	var list []account.Account
	if err := a.s.R.List(ctx, "accounts", database.Filter{
		Equal: map[string]any{"kind": string(account.KindUser)},
	}, &list); err != nil {
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
	return helper.JSON(map[string]any{"users": page(out, limit, offset)})
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
		To          string   `json:"to"`
		Body        string   `json:"body"`
		ReplyTo     string   `json:"reply_to,omitempty"`
		Attachments []string `json:"attachments,omitempty"`
		// Voice: the note was spoken in a live voice chat, so its answer is wanted fast and short (brain.go).
		Voice bool `json:"voice,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if in.Body == "" && len(in.Attachments) == 0 {
		return nil, errs.InvalidArgument("body required")
	}
	if resp, ok, err := helper.ProxyIfRemote(ctx, a.s.K, in.To, "users", "dm_send", req); ok {
		return resp, err
	}
	to, err := identity.Parse(in.To)
	if err != nil {
		return nil, err
	}
	// Built-in Aseman assistant / lead is the personal Aseman chat (self), not
	// a separate person↔bot Direct or AskDirect turn.
	if rec, ok := a.s.botOf(ctx, to); ok && rec.IsBuiltin() {
		to = req.Caller.ID
	}
	if blocked, byMe, err := a.s.directBlocked(ctx, req.Caller.ID, to); err != nil {
		return nil, err
	} else if blocked && byMe {
		return nil, errs.New(errs.CodePermission, "You blocked this person. Unblock them to send a message.")
	} else if blocked {
		return nil, errs.New(errs.CodePermission, "You can't message this person.")
	}
	if err := a.s.messageAllowed(ctx, req.Caller.ID, to); err != nil {
		return nil, err
	}
	if err := a.s.directAllowed(ctx, req.Caller.ID, to); err != nil {
		return nil, err
	}
	if in.ReplyTo != "" {
		// A reply answers a message of this same conversation.
		rid, err := identity.Parse(in.ReplyTo)
		if err != nil {
			return nil, err
		}
		orig, err := a.s.getDirect(ctx, rid)
		if err != nil {
			return nil, errs.InvalidArgument("the message you reply to is not there")
		}
		pair := orig.From == req.Caller.ID && orig.To == to || orig.From == to && orig.To == req.Caller.ID
		if !pair {
			return nil, errs.InvalidArgument("you can only reply to a message of this conversation")
		}
	}
	files, err := a.s.claimAttachments(ctx, req.Caller.ID, to, in.Attachments)
	if err != nil {
		return nil, err
	}
	if len(files) > 0 {
		if err := a.s.canSendFiles(ctx, req.Caller.ID, to); err != nil {
			return nil, err
		}
	}
	id, err := identity.New(a.s.K.NodeID())
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	dm := &message.Direct{
		Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		From:   req.Caller.ID, To: to, Body: in.Body, SentAt: now, ReplyTo: in.ReplyTo,
	}
	if len(files) > 0 {
		ids := make([]string, len(files))
		for i, f := range files {
			ids[i] = f.ID
		}
		raw, _ := json.Marshal(ids)
		dm.AttachmentIDs = string(raw)
	}
	if err := a.s.storeDirect(ctx, dm); err != nil {
		return nil, err
	}
	a.s.linkAttachments(ctx, files, id.String())
	// Writing to someone means you have read the conversation so far, and
	// that you stopped typing.
	_, _ = a.s.updateDirectState(ctx, req.Caller.ID, to, func(st *directState) { st.ReadAt = now })
	typing.set(req.Caller.ID, to, false)
	// Keep the messenger's direct / Saved Messages room in sync (with Direct id).
	a.s.mirrorDirectID(ctx, req.Caller.ID, to, in.Body, id)
	if _, agent := a.s.agentAccount(ctx, to); !agent && to != req.Caller.ID {
		go a.s.notifyDirect(context.WithoutCancel(ctx), *dm)
	}
	// A note to oneself is read by one's own Aseman: kept, or answered.
	if to == req.Caller.ID {
		names := make([]string, len(files))
		for i, f := range files {
			names[i] = f.Name
		}
		a.s.startBrain(ctx, req.Caller.ID, brainNote{msg: dm, files: names, voice: in.Voice})
	}
	// A message to an agent is a conversation with it: the agent answers in
	// the same direct thread, without holding up this request. An agent
	// messaging another agent inside a run keeps that run's scope.
	if botID, ok := a.s.agentAccount(ctx, to); ok && to != req.Caller.ID {
		// It joins that run before going off on its own, so stopping the run
		// stops it too and the run's turn waits for it.
		deliver, leave := a.s.joinRun(helper.WithActor(context.WithoutCancel(ctx), req.Caller.ID))
		go func() {
			defer leave()
			a.s.deliverDirect(deliver, req.Caller.ID, to, botID, in.Body)
		}()
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
	// Saved Messages (a conversation with oneself) is one direction only.
	if peer != req.Caller.ID {
		if err := a.s.R.List(ctx, "directs", database.Filter{
			Equal:   map[string]any{"from_id": peer.String(), "to_id": req.Caller.ID.String()},
			OrderBy: "created_at", Asc: false, Limit: in.Limit,
		}, &theirs); err != nil {
			return nil, err
		}
	}
	me, _, err := a.s.directStateOf(ctx, req.Caller.ID, peer)
	if err != nil {
		return nil, err
	}
	them, _, err := a.s.directStateOf(ctx, peer, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	hidden, err := a.s.hiddenDirects(ctx, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	all := append(mine, theirs...)
	// A message its sender took back is gone from the conversation for both
	// sides (no "deleted" placeholder), and a reply to it no longer quotes it.
	gone := map[string]bool{}
	for _, dm := range all {
		if !dm.DeletedAt.IsZero() {
			gone[dm.ID.String()] = true
		}
	}
	out := all[:0]
	replyGone := map[string]bool{}
	for _, dm := range all {
		// A conversation the caller deleted shows only what came after.
		if !me.ClearedAt.IsZero() && !dm.CreatedAt.After(me.ClearedAt) || !dm.DeletedAt.IsZero() || hidden[dm.ID.String()] {
			continue // before the caller cleared the chat, taken back, or deleted for the caller
		}
		if gone[dm.ReplyTo] || hidden[dm.ReplyTo] {
			// The message it answered is not there for the caller: the reply
			// says so instead of passing for a message of its own.
			replyGone[dm.ID.String()] = true
		}
		out = append(out, dm)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.After(out[j].CreatedAt) })
	if len(out) > in.Limit {
		out = out[:in.Limit]
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	reacted := a.s.directReactions(ctx, out)
	// Which of the files the caller has kept.
	var fileIDs []string
	for i := range out {
		fileIDs = append(fileIDs, attachmentIDs(&out[i])...)
	}
	kept := a.s.keptOf(ctx, req.Caller.ID, fileIDs)
	views := make([]map[string]any, 0, len(out))
	agents := map[string]map[string]any{}
	for i := range out {
		a.s.openDirect(&out[i])
		v := directView(out[i])
		if replyGone[out[i].ID.String()] {
			v["reply_deleted"] = true
		}
		if rs := reacted[out[i].ID.String()]; len(rs) > 0 {
			v["reactions"] = rs
		}
		if atts := a.s.attachmentsOf(ctx, &out[i]); len(atts) > 0 {
			for _, att := range atts {
				if id, _ := att["id"].(string); kept[id] != "" {
					att["kept"] = true
				}
			}
			v["attachments"] = atts
		}
		// An agent's answer in the notes carries who wrote it.
		if aid := out[i].AgentID; aid != "" {
			if agents[aid] == nil {
				if id, err := identity.Parse(aid); err == nil {
					agents[aid] = a.s.publicRef(ctx, req.Caller.ID, id)
				}
			}
			if ref := agents[aid]; ref != nil {
				v["agent"] = ref
			}
		}
		views = append(views, v)
	}
	view := map[string]any{"messages": views,
		// Calls between the two, finished, to show in the chat among the messages.
		"calls":       a.s.callHistory(ctx, req.Caller.ID, peer, me.ClearedAt, in.Limit),
		"peer_typing": typing.is(peer, req.Caller.ID),
		// How far the peer has read: the client marks the caller's messages up to it as seen.
		"peer_read_at": nullTime(them.ReadAt),
		"blocked":      me.Blocked,
		"can_send":     !me.Blocked && !them.Blocked && a.s.messageAllowed(ctx, req.Caller.ID, peer) == nil,
		// A block, either way: what stops a call as well (calls have their own choices).
		"blocked_either": me.Blocked || them.Blocked,
	}
	// The assistant still writing an answer in this conversation (shown as "thinking", then its text as it grows).
	view["agents_working"] = a.s.workingAsks(ctx, req.Caller.ID, convKey(req.Caller.ID, peer))
	return helper.JSON(view)
}

// nullTime is a time for JSON, or null when it was never set.
func nullTime(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t
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
	states, err := a.s.directStates(ctx, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	hidden, err := a.s.hiddenDirects(ctx, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	// What the caller has not read yet: the peer's messages after both the
	// caller's read point and the point they deleted the conversation.
	unread := map[string]int{}
	for _, dm := range received {
		if dm.From == req.Caller.ID {
			continue // a note to oneself is never unread
		}
		st := states[dm.From.String()]
		if dm.DeletedAt.IsZero() && !hidden[dm.ID.String()] && dm.CreatedAt.After(st.ReadAt) && dm.CreatedAt.After(st.ClearedAt) {
			unread[dm.From.String()]++
		}
	}
	all := append([]message.Direct{}, sent...)
	for _, dm := range received {
		if dm.From != req.Caller.ID { // notes to oneself are already among the sent
			all = append(all, dm)
		}
	}
	sort.Slice(all, func(i, j int) bool { return all[i].CreatedAt.After(all[j].CreatedAt) })
	threads := []map[string]any{}
	pinnedAt := map[string]time.Time{}
	seen := map[string]bool{}
	total := 0
	for _, dm := range all {
		peer := dm.To
		if dm.To == req.Caller.ID {
			peer = dm.From
		}
		st := states[peer.String()]
		if seen[peer.String()] || !st.ClearedAt.IsZero() && !dm.CreatedAt.After(st.ClearedAt) {
			continue // a deleted conversation returns only with a newer message
		}
		if !dm.DeletedAt.IsZero() || hidden[dm.ID.String()] {
			continue // the preview is the newest message still there for the caller
		}
		seen[peer.String()] = true
		a.s.openDirect(&dm)
		n := unread[peer.String()]
		total += n
		thread := map[string]any{"peer": a.s.publicRef(ctx, req.Caller.ID, peer), "last": a.s.directViewWithFiles(ctx, dm), "unread": n, "blocked": st.Blocked,
			"typing": typing.is(peer, req.Caller.ID), "saved": peer == req.Caller.ID}
		if !st.PinnedAt.IsZero() {
			thread["pinned_at"] = st.PinnedAt
			pinnedAt[peer.String()] = st.PinnedAt
		}
		threads = append(threads, thread)
	}
	// Pinned chats first, the latest pinned on top; the rest stay newest first.
	// The limit applies after, so a pinned chat is never cut for a newer one.
	sort.SliceStable(threads, func(i, j int) bool {
		pi, pj := pinnedAt[threadPeer(threads[i])], pinnedAt[threadPeer(threads[j])]
		if pi.IsZero() != pj.IsZero() {
			return !pi.IsZero()
		}
		return pi.After(pj)
	})
	if len(threads) > in.Limit {
		threads = threads[:in.Limit]
	}
	return helper.JSON(map[string]any{"threads": threads, "unread_total": total})
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
	// A file is for the people it was shared with: knowing its id is not enough.
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
	if err := a.s.canReadFile(ctx, id, req.Caller.ID); err != nil {
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
	if err := a.s.R.Delete(ctx, "files", id); err != nil {
		return nil, err
	}
	a.s.releaseFileBytes(ctx, file)
	return helper.JSON(map[string]any{"ok": true})
}

// threadPeer is the id of a thread row's peer.
func threadPeer(t map[string]any) string {
	ref, _ := t["peer"].(map[string]any)
	id, _ := ref["id"].(string)
	return id
}
