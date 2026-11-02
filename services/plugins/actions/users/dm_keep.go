package users

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Keeping a file someone sent you. It is manual, so nobody can fill another
// person's storage by sending files. Keeping makes the person a file record of
// their own — it counts against their storage and survives the sender deleting
// the message — that uses the same stored bytes as the sender's, not a second
// copy (fileref.Release deletes the bytes only when the last record goes).

// keptFile is one file a person kept from a chat.
type keptFile struct {
	ID        string    `db:"id" json:"id"` // the person's own file record
	OwnerID   string    `db:"owner_id" json:"owner_id"`
	FromID    string    `db:"from_id" json:"from_id"`
	SourceID  string    `db:"source_id" json:"source_id"` // the sender's file
	MessageID string    `db:"message_id" json:"message_id"`
	Name      string    `db:"name" json:"name"`
	Mime      string    `db:"mime" json:"mime"`
	Size      int64     `db:"size" json:"size"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
}

// keptOf says which of the files (by the sender's file id) `owner` has kept, and
// under which record of their own.
func (s *Service) keptOf(ctx context.Context, owner identity.ID, sourceIDs []string) map[string]string {
	out := map[string]string{}
	if len(sourceIDs) == 0 {
		return out
	}
	in := make([]any, len(sourceIDs))
	for i, id := range sourceIDs {
		in[i] = id
	}
	var rows []keptFile
	if err := s.R.List(ctx, "kept_files", database.Filter{Equal: map[string]any{"owner_id": owner.String()}, In: map[string][]any{"source_id": in}}, &rows); err != nil {
		return out // a marker is a garnish: the chat still loads
	}
	for _, r := range rows {
		out[r.SourceID] = r.ID
	}
	return out
}

// dmKeep keeps the files of a message the caller received: {"message": id} for
// all of them, or with {"file": id} for one. Keeping again is a no-op.
func (s *Service) dmKeep(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Message string `json:"message"`
		File    string `json:"file"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	me := req.Caller.ID
	mid, err := identity.Parse(in.Message)
	if err != nil {
		return nil, err
	}
	dm, err := s.getDirect(ctx, mid)
	if err != nil {
		return nil, err
	}
	if dm.To != me || dm.From == me {
		return nil, errs.InvalidArgument("only a file someone sent you can be kept")
	}
	if !dm.DeletedAt.IsZero() {
		return nil, errs.Conflict("this message was deleted")
	}
	ids := attachmentIDs(dm)
	if in.File != "" {
		found := false
		for _, id := range ids {
			found = found || id == in.File
		}
		if !found {
			return nil, errs.InvalidArgument("that file is not in this message")
		}
		ids = []string{in.File}
	}
	if len(ids) == 0 {
		return nil, errs.InvalidArgument("this message has no files")
	}

	already := s.keptOf(ctx, me, ids)
	var todo []directAttachment
	var add int64
	for _, id := range ids {
		if already[id] != "" {
			continue
		}
		var row directAttachment
		if s.R.GetString(ctx, "direct_attachments", id, &row) != nil || row.PeerID != me.String() || row.MessageID != mid.String() {
			return nil, errs.Conflict("a file is no longer available")
		}
		todo = append(todo, row)
		add += row.Size
	}
	if err := s.storageGate(ctx, me, add); err != nil {
		return nil, err
	}

	kept := already
	for _, row := range todo {
		sid, err := identity.Parse(row.ID)
		if err != nil {
			return nil, err
		}
		var src filedata.File
		if err := s.R.Get(ctx, "files", sid, &src); err != nil {
			return nil, errs.Conflict("a file is no longer available")
		}
		own, err := identity.New(s.K.NodeID())
		if err != nil {
			return nil, err
		}
		now := time.Now().UTC()
		// A record of their own over the same bytes.
		copyOf := &filedata.File{Entity: entity.Entity{ID: own, CreatedAt: now, UpdatedAt: now}, OwnerID: me, Name: src.Name, Mime: src.Mime, Size: src.Size, StorageKey: src.StorageKey}
		if err := s.R.CreateID(ctx, "files", own, copyOf); err != nil {
			return nil, err
		}
		link := &keptFile{ID: own.String(), OwnerID: me.String(), FromID: dm.From.String(), SourceID: row.ID, MessageID: mid.String(), Name: src.Name, Mime: src.Mime, Size: src.Size, CreatedAt: now}
		if err := s.R.DB.Create(ctx, "kept_files", link.ID, link); err != nil {
			_ = s.R.Delete(ctx, "files", own)
			return nil, err
		}
		// The sender may have deleted it a moment ago: if the bytes are gone, undo.
		if fs := s.K.FS(); fs != nil {
			if ok, err := fs.Exists(ctx, src.StorageKey); err == nil && !ok {
				_ = s.R.DB.Delete(ctx, "kept_files", link.ID)
				_ = s.R.Delete(ctx, "files", own)
				return nil, errs.Conflict("a file is no longer available")
			}
		}
		kept[row.ID] = own.String()
	}
	return helper.JSON(map[string]any{"ok": true, "kept": kept})
}
