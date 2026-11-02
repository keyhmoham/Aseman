package users

import (
	"context"
	"encoding/json"
	"sort"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// A person's storage is what they are responsible for:
//
//   - chats: the files they sent in direct messages (their own notes included);
//   - kept: files they chose to keep from chats others sent them (the bytes are
//     shared with the sender's file, but the whole size is theirs to carry);
//   - rooms: every file in the rooms they own, whoever uploaded it;
//   - other: what they uploaded outside rooms and chats (a profile picture, a post's media).
//
// A file a member uploads into someone else's room is the room owner's, not
// the member's. One function adds this up (storageSummary), for the screen and
// for the upload check alike, so they can never disagree.

// maxGroups bounds how many chats and rooms the overview lists (largest first).
const maxGroups = 100

// storagePage is how many files one page lists.
const storagePage = 50

// maxStorageDelete is how many files one delete may name.
const maxStorageDelete = 100

type storageGroup struct {
	ID    string // the peer's account id (chats) or the room's id
	Bytes int64
	Files int64
	Name  string // rooms only
}

type storageSummary struct {
	Chats, Rooms []storageGroup
	Kept         []storageGroup
	KeptBytes    int64
	ChatsBytes   int64
	RoomsBytes   int64
	OtherBytes   int64
	Files        int64
}

func (t storageSummary) total() int64 {
	return t.ChatsBytes + t.KeptBytes + t.RoomsBytes + t.OtherBytes
}

// storageSummaryOf adds up what `user` is responsible for.
func (s *Service) storageSummaryOf(ctx context.Context, user identity.ID) (storageSummary, error) {
	var out storageSummary

	// Chats: the links say which chat each file was sent in.
	var links []directAttachment
	if err := s.R.List(ctx, "direct_attachments", database.Filter{Equal: map[string]any{"owner_id": user.String()}}, &links); err != nil {
		return out, err
	}
	inChat := make(map[string]bool, len(links))
	byPeer := map[string]*storageGroup{}
	for _, l := range links {
		inChat[l.ID] = true
		g := byPeer[l.PeerID]
		if g == nil {
			g = &storageGroup{ID: l.PeerID}
			byPeer[l.PeerID] = g
		}
		g.Bytes += l.Size
		g.Files++
		out.ChatsBytes += l.Size
		out.Files++
	}

	// Files they kept from chats, by who sent them.
	var keptRows []keptFile
	if err := s.R.List(ctx, "kept_files", database.Filter{Equal: map[string]any{"owner_id": user.String()}}, &keptRows); err != nil {
		return out, err
	}
	isKept := make(map[string]bool, len(keptRows))
	byFrom := map[string]*storageGroup{}
	for _, k := range keptRows {
		isKept[k.ID] = true
		g := byFrom[k.FromID]
		if g == nil {
			g = &storageGroup{ID: k.FromID}
			byFrom[k.FromID] = g
		}
		g.Bytes += k.Size
		g.Files++
		out.KeptBytes += k.Size
		out.Files++
	}

	// What they uploaded outside rooms and chats.
	var mine []filedata.File
	if err := s.R.List(ctx, "files", database.Filter{Equal: map[string]any{"owner_id": user.String()}}, &mine); err != nil {
		return out, err
	}
	for _, f := range mine {
		if f.SpaceID.IsZero() && !inChat[f.ID.String()] && !isKept[f.ID.String()] {
			out.OtherBytes += f.Size
			out.Files++
		}
	}

	// Rooms they own: all of their files, from anyone.
	var owned []space.Space
	if err := s.R.List(ctx, "spaces", database.Filter{Equal: map[string]any{"owner_id": user.String()}}, &owned); err != nil {
		return out, err
	}
	if len(owned) > 0 {
		ids := make([]any, len(owned))
		names := make(map[string]string, len(owned))
		for i, sp := range owned {
			ids[i] = sp.ID.String()
			names[sp.ID.String()] = sp.Name
		}
		var files []filedata.File
		if err := s.R.List(ctx, "files", database.Filter{In: map[string][]any{"space_id": ids}}, &files); err != nil {
			return out, err
		}
		byRoom := map[string]*storageGroup{}
		for _, f := range files {
			key := f.SpaceID.String()
			g := byRoom[key]
			if g == nil {
				g = &storageGroup{ID: key, Name: names[key]}
				byRoom[key] = g
			}
			g.Bytes += f.Size
			g.Files++
			out.RoomsBytes += f.Size
			out.Files++
		}
		for _, g := range byRoom {
			out.Rooms = append(out.Rooms, *g)
		}
	}
	for _, g := range byPeer {
		out.Chats = append(out.Chats, *g)
	}
	for _, g := range byFrom {
		out.Kept = append(out.Kept, *g)
	}
	largest := func(list []storageGroup) {
		sort.Slice(list, func(i, j int) bool { return list[i].Bytes > list[j].Bytes })
	}
	largest(out.Chats)
	largest(out.Kept)
	largest(out.Rooms)
	return out, nil
}

// storageGate refuses an upload that would take a person past their limit.
func (s *Service) storageGate(ctx context.Context, user identity.ID, add int64) error {
	limit := s.storageLimit(ctx)
	if limit == 0 {
		return nil
	}
	sum, err := s.storageSummaryOf(ctx, user)
	if err != nil {
		return err
	}
	if sum.total()+add > limit {
		return errs.New(errs.CodeConflict, "Your storage is full. Delete something to make room.")
	}
	return nil
}

// storageUsage is the overview: the total, the limit, and the largest chats and rooms.
func (s *Service) storageUsage(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	me := req.Caller.ID
	sum, err := s.storageSummaryOf(ctx, me)
	if err != nil {
		return nil, err
	}
	chats := make([]map[string]any, 0, len(sum.Chats))
	for i, g := range sum.Chats {
		if i == maxGroups {
			break
		}
		row := map[string]any{"bytes": g.Bytes, "files": g.Files, "saved": g.ID == me.String()}
		if peer, e := identity.Parse(g.ID); e == nil {
			row["peer"] = s.publicRef(ctx, me, peer)
		}
		chats = append(chats, row)
	}
	kept := make([]map[string]any, 0, len(sum.Kept))
	for i, g := range sum.Kept {
		if i == maxGroups {
			break
		}
		row := map[string]any{"bytes": g.Bytes, "files": g.Files, "saved": false}
		if from, e := identity.Parse(g.ID); e == nil {
			row["peer"] = s.publicRef(ctx, me, from)
		}
		kept = append(kept, row)
	}
	rooms := make([]map[string]any, 0, len(sum.Rooms))
	for i, g := range sum.Rooms {
		if i == maxGroups {
			break
		}
		rooms = append(rooms, map[string]any{"id": g.ID, "name": g.Name, "bytes": g.Bytes, "files": g.Files})
	}
	return helper.JSON(map[string]any{
		"used_bytes": sum.total(), "files": sum.Files, "limit_bytes": s.storageLimit(ctx),
		"chats_bytes": sum.ChatsBytes, "kept_bytes": sum.KeptBytes, "rooms_bytes": sum.RoomsBytes, "other_bytes": sum.OtherBytes,
		"chats": chats, "kept": kept, "rooms": rooms,
	})
}

// ownsRoom says whether `user` owns the room (space) `id`.
func (s *Service) ownsRoom(ctx context.Context, user identity.ID, id string) bool {
	var sp space.Space
	return s.R.GetString(ctx, "spaces", id, &sp) == nil && sp.OwnerID == user
}

// storageFiles lists one chat's or one room's files, newest first, a page at a
// time: {"kind": "chat"|"room", "id": peer or room id, "before": cursor}.
func (s *Service) storageFiles(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Kind   string    `json:"kind"`
		ID     string    `json:"id"`
		Before time.Time `json:"before"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	me := req.Caller.ID
	f := database.Filter{OrderBy: "created_at", Asc: false, Limit: storagePage + 1}
	if !in.Before.IsZero() {
		f.LessThan = map[string]any{"created_at": in.Before}
	}
	var items []map[string]any
	var created []time.Time
	switch in.Kind {
	case "chat":
		f.Equal = map[string]any{"owner_id": me.String(), "peer_id": in.ID}
		var rows []directAttachment
		if err := s.R.List(ctx, "direct_attachments", f, &rows); err != nil {
			return nil, err
		}
		for _, r := range rows {
			v := r.view()
			v["created_at"], v["message_id"] = r.CreatedAt, r.MessageID
			items, created = append(items, v), append(created, r.CreatedAt)
		}
	case "kept":
		f.Equal = map[string]any{"owner_id": me.String(), "from_id": in.ID}
		var rows []keptFile
		if err := s.R.List(ctx, "kept_files", f, &rows); err != nil {
			return nil, err
		}
		for _, r := range rows {
			v := map[string]any{"id": r.ID, "file_id": r.ID, "name": r.Name, "mime": r.Mime, "size": r.Size,
				"content_url": "/v1/files/" + r.ID + "/content", "created_at": r.CreatedAt, "message_id": r.MessageID}
			items, created = append(items, v), append(created, r.CreatedAt)
		}
	case "room":
		if !s.ownsRoom(ctx, me, in.ID) {
			return nil, errs.New(errs.CodePermission, "only the room's owner can see its storage")
		}
		f.Equal = map[string]any{"space_id": in.ID}
		var rows []filedata.File
		if err := s.R.List(ctx, "files", f, &rows); err != nil {
			return nil, err
		}
		for _, r := range rows {
			v := map[string]any{"id": r.ID.String(), "file_id": r.ID.String(), "name": r.Name, "mime": r.Mime, "size": r.Size,
				"content_url": "/v1/files/" + r.ID.String() + "/content", "created_at": r.CreatedAt}
			if r.OwnerID != me {
				v["uploader"] = s.publicRef(ctx, me, r.OwnerID)
			}
			items, created = append(items, v), append(created, r.CreatedAt)
		}
	default:
		return nil, errs.InvalidArgument("kind must be chat, kept or room")
	}
	more := len(items) > storagePage
	var next any
	if more {
		items = items[:storagePage]
		next = created[storagePage-1]
	}
	if items == nil {
		items = []map[string]any{}
	}
	return helper.JSON(map[string]any{"files": items, "next": next})
}

// storageDelete deletes files to free space. For a chat they are files the
// caller sent (the message loses them, and goes if nothing is left of it); for
// a room, any file in a room the caller owns.
func (s *Service) storageDelete(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Kind  string   `json:"kind"`
		Files []string `json:"files"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if len(in.Files) == 0 || len(in.Files) > maxStorageDelete {
		return nil, errs.InvalidArgument("name between 1 and 100 files")
	}
	me := req.Caller.ID
	var freed, deleted int64
	for _, id := range in.Files {
		switch in.Kind {
		case "chat":
			var row directAttachment
			if s.R.GetString(ctx, "direct_attachments", id, &row) != nil || row.OwnerID != me.String() {
				continue // gone already, or not theirs: nothing to do, nothing to reveal
			}
			s.removeFromMessage(ctx, row)
			s.dropAttachment(ctx, row)
			freed, deleted = freed+row.Size, deleted+1
		case "kept":
			var row keptFile
			fid, err := identity.Parse(id)
			if err != nil || s.R.DB.Get(ctx, "kept_files", id, &row) != nil || row.OwnerID != me.String() {
				continue
			}
			var f filedata.File
			_ = s.R.Get(ctx, "files", fid, &f)
			_ = s.R.DB.Delete(ctx, "kept_files", id)
			if s.R.Delete(ctx, "files", fid) == nil {
				s.releaseFileBytes(ctx, &f) // the sender's file, if still there, keeps the bytes
			}
			freed, deleted = freed+row.Size, deleted+1
		case "room":
			fid, err := identity.Parse(id)
			if err != nil {
				continue
			}
			var f filedata.File
			if s.R.Get(ctx, "files", fid, &f) != nil || f.SpaceID.IsZero() || !s.ownsRoom(ctx, me, f.SpaceID.String()) {
				continue
			}
			if s.R.Delete(ctx, "files", fid) == nil {
				s.releaseFileBytes(ctx, &f)
				freed, deleted = freed+f.Size, deleted+1
			}
		default:
			return nil, errs.InvalidArgument("kind must be chat, kept or room")
		}
	}
	return helper.JSON(map[string]any{"ok": true, "deleted": deleted, "freed_bytes": freed})
}

// removeFromMessage takes a deleted file out of the message that carried it; a
// message left with no text and no files is taken back.
func (s *Service) removeFromMessage(ctx context.Context, row directAttachment) {
	if row.MessageID == "" {
		return
	}
	mid, err := identity.Parse(row.MessageID)
	if err != nil {
		return
	}
	dm, err := s.getDirect(ctx, mid)
	if err != nil {
		return
	}
	kept := []string{}
	for _, id := range attachmentIDs(dm) {
		if id != row.ID {
			kept = append(kept, id)
		}
	}
	if len(kept) == 0 {
		dm.AttachmentIDs = ""
		if dm.Body == "" {
			dm.DeletedAt = time.Now().UTC()
		}
	} else {
		raw, _ := json.Marshal(kept)
		dm.AttachmentIDs = string(raw)
	}
	_ = s.saveDirect(ctx, dm)
}
