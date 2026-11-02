package users

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/spaces/models/filedata"
	"github.com/aseman/aseman/plugins/actions/support/fileref"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Files in direct messages. A photo, video, voice note or document is stored
// as an ordinary file owned by whoever sent it, so it counts against *their*
// storage (storage_usage below; storageGate is the one place a limit or a
// price per GB would be enforced). The `direct_attachments` row says who may
// open it: the sender, and, once the message is sent, the person it was sent to.
// Unsending the message deletes the file and gives the storage back.

// maxDirectFile is the largest file one message may carry.
const maxDirectFile = 32 << 20

// maxDirectAttachments is how many files one message may carry.
const maxDirectAttachments = 10

// stalePending is how long an upload that never went into a message is kept.
const stalePending = time.Hour

// directAttachment is one file sent (or about to be sent) in a direct message.
type directAttachment struct {
	ID        string `db:"id" json:"id"` // the file's id
	OwnerID   string `db:"owner_id" json:"owner_id"`
	PeerID    string `db:"peer_id" json:"peer_id"`
	MessageID string `db:"message_id" json:"message_id"`
	Name      string `db:"name" json:"name"`
	Mime      string `db:"mime" json:"mime"`
	Size      int64  `db:"size" json:"size"`
	// Voice marks a voice message (a recording made in the app, not an audio
	// file that was picked); DurationMS is how long it plays, as the recorder
	// measured it (informational: the player shows it before the file loads).
	Voice      bool  `db:"voice" json:"voice,omitempty"`
	DurationMS int64 `db:"duration_ms" json:"duration_ms,omitempty"`
	// Waveform is the loudness of the recording over time, a JSON list of
	// bars (0-100) the chat draws as the message's sound wave without
	// decoding the audio.
	Waveform  string    `db:"waveform" json:"-"`
	CreatedAt time.Time `db:"created_at" json:"created_at"`
}

// maxWaveformBars bounds the wave a client may send.
const maxWaveformBars = 128

// cleanWaveform keeps at most maxWaveformBars bars, each 0-100, as the JSON
// stored with the file; an empty or unusable wave is none.
func cleanWaveform(bars []int) string {
	if len(bars) == 0 {
		return ""
	}
	if len(bars) > maxWaveformBars {
		bars = bars[:maxWaveformBars]
	}
	out := make([]int, len(bars))
	for i, b := range bars {
		out[i] = min(max(b, 0), 100)
	}
	raw, err := json.Marshal(out)
	if err != nil {
		return ""
	}
	return string(raw)
}

// maxVoiceMS is the longest voice message the node believes (10 minutes).
const maxVoiceMS = 10 * 60 * 1000

func (a directAttachment) view() map[string]any {
	v := map[string]any{"file_id": a.ID, "id": a.ID, "name": a.Name, "mime": a.Mime, "size": a.Size, "content_url": "/v1/files/" + a.ID + "/content"}
	if a.Voice {
		v["voice"], v["duration_ms"] = true, a.DurationMS
		if a.Waveform != "" {
			var bars []int
			if json.Unmarshal([]byte(a.Waveform), &bars) == nil {
				v["waveform"] = bars
			}
		}
	}
	return v
}

func dmFileActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "users", Name: "dm_file_upload", Summary: "Upload a file to send in a direct message", Handler: s.dmFileUpload},
		helper.Action{Namespace: "users", Name: "dm_keep", Summary: "Keep the files of a message you received, in your own storage", Handler: s.dmKeep},
		helper.Action{Namespace: "users", Name: "storage_usage", Summary: "How much storage the caller uses, by chat and by room they own", Handler: s.storageUsage},
		helper.Action{Namespace: "users", Name: "storage_files", Summary: "A page of the files behind one chat or room in the caller's storage", Handler: s.storageFiles},
		helper.Action{Namespace: "users", Name: "storage_delete", Summary: "Delete files from the caller's storage to free space", Handler: s.storageDelete},
	}
}

// storageLimit is the most storage one person may use, in bytes; 0 means no
// limit. The admin sets it (Settings → Storage); a plan or a price per GB would
// replace this one function.
func (s *Service) storageLimit(ctx context.Context) int64 {
	if s.StorageLimit != nil {
		return s.StorageLimit(ctx)
	}
	if s.K == nil {
		return 0
	}
	var st struct {
		LimitMB int64 `json:"limit_mb"`
	}
	if err := bridge.Invoke(ctx, s.K, "settings", "Storage", []any{ctx}, &st); err != nil || st.LimitMB <= 0 {
		return 0
	}
	return st.LimitMB << 20
}

// dmFileUpload stores a file for a direct message to `to`; it goes into a message
// with dm_send's `attachments`.
func (s *Service) dmFileUpload(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		To   string `json:"to"`
		Name string `json:"name"`
		Mime string `json:"mime"`
		Data []byte `json:"data"` // base64 in the transport
		// Voice sends the recording as a voice message; DurationMS is how long it plays.
		Voice      bool  `json:"voice,omitempty"`
		DurationMS int64 `json:"duration_ms,omitempty"`
		Waveform   []int `json:"waveform,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	to, err := identity.Parse(in.To)
	if err != nil {
		return nil, err
	}
	if err := s.canSendFiles(ctx, req.Caller.ID, to); err != nil {
		return nil, err
	}
	name := cleanFileName(in.Name)
	if name == "" || len(in.Data) == 0 {
		return nil, errs.InvalidArgument("name and data required")
	}
	if len(in.Data) > maxDirectFile {
		return nil, errs.InvalidArgument("that file is too large (the most is 32 MB)")
	}
	if err := s.storageGate(ctx, req.Caller.ID, int64(len(in.Data))); err != nil {
		return nil, err
	}
	s.dropStalePending(ctx, req.Caller.ID)
	mime := strings.TrimSpace(in.Mime)
	if mime == "" || mime == "application/octet-stream" {
		mime = http.DetectContentType(in.Data)
	}
	if in.Voice && !strings.HasPrefix(mime, "audio/") {
		return nil, errs.InvalidArgument("a voice message must be audio")
	}
	file, err := s.UploadFile(ctx, req.Caller.ID, name, mime, int64(len(in.Data)), bytes.NewReader(in.Data), "")
	if err != nil {
		return nil, err
	}
	row := &directAttachment{ID: file.ID.String(), OwnerID: req.Caller.ID.String(), PeerID: to.String(), Name: name, Mime: mime, Size: file.Size, CreatedAt: time.Now().UTC()}
	if in.Voice {
		row.Voice, row.DurationMS, row.Waveform = true, min(max(in.DurationMS, 0), maxVoiceMS), cleanWaveform(in.Waveform)
	}
	if err := s.R.DB.Create(ctx, "direct_attachments", row.ID, row); err != nil {
		_ = s.R.Delete(ctx, "files", file.ID)
		s.releaseFileBytes(ctx, file)
		return nil, err
	}
	return helper.JSON(row.view())
}

// canSendFiles says whether `from` may send files to `to`: a person on this node
// who has not blocked them (or the sender's own notes), not an agent.
func (s *Service) canSendFiles(ctx context.Context, from, to identity.ID) error {
	if blocked, byMe, err := s.directBlocked(ctx, from, to); err != nil {
		return err
	} else if blocked && byMe {
		return errs.New(errs.CodePermission, "You blocked this person. Unblock them to send a message.")
	} else if blocked {
		return errs.New(errs.CodePermission, "You can't message this person.")
	}
	if err := s.messageAllowed(ctx, from, to); err != nil {
		return err
	}
	if _, agent := s.agentAccount(ctx, to); agent {
		return errs.InvalidArgument("agents can't open files in a direct chat yet")
	}
	var acc account.Account
	if err := s.R.Get(ctx, "accounts", to, &acc); err != nil {
		return errs.InvalidArgument("files can only be sent to people on this node")
	}
	return nil
}

func cleanFileName(name string) string {
	name = strings.TrimSpace(strings.NewReplacer("/", "_", "\\", "_", "\x00", "").Replace(name))
	if len(name) > 255 {
		name = name[:255]
	}
	return name
}

// releaseFileBytes deletes a file's bytes once no record uses them: call it after
// the record is deleted (a kept file shares the bytes of the one it came from).
func (s *Service) releaseFileBytes(ctx context.Context, f *filedata.File) {
	if fs := s.K.FS(); fs != nil {
		_ = fileref.Release(ctx, s.R, fs, f.StorageKey)
	}
}

// dropStalePending removes the caller's uploads that never went into a message.
func (s *Service) dropStalePending(ctx context.Context, owner identity.ID) {
	var rows []directAttachment
	if err := s.R.List(ctx, "direct_attachments", database.Filter{Equal: map[string]any{"owner_id": owner.String(), "message_id": ""}}, &rows); err != nil {
		return
	}
	for _, r := range rows {
		if time.Since(r.CreatedAt) > stalePending {
			s.dropAttachment(ctx, r)
		}
	}
}

// dropAttachment deletes a sent file for good: its bytes, its file row and its link.
func (s *Service) dropAttachment(ctx context.Context, a directAttachment) {
	id, err := identity.Parse(a.ID)
	if err != nil {
		return
	}
	var f filedata.File
	if s.R.Get(ctx, "files", id, &f) == nil {
		_ = s.R.Delete(ctx, "files", id)
		s.releaseFileBytes(ctx, &f)
	}
	_ = s.R.DB.Delete(ctx, "direct_attachments", a.ID)
}

// attachmentIDs are the files a message carries.
func attachmentIDs(dm *message.Direct) []string {
	if dm.AttachmentIDs == "" {
		return nil
	}
	var out []string
	if json.Unmarshal([]byte(dm.AttachmentIDs), &out) != nil {
		return nil
	}
	return out
}

// attachmentsOf are a message's files as a client reads them.
func (s *Service) attachmentsOf(ctx context.Context, dm *message.Direct) []map[string]any {
	ids := attachmentIDs(dm)
	out := make([]map[string]any, 0, len(ids))
	for _, id := range ids {
		var row directAttachment
		if s.R.GetString(ctx, "direct_attachments", id, &row) == nil {
			out = append(out, row.view())
		}
	}
	return out
}

// directViewWithFiles is a message as a client reads it, with its files.
func (s *Service) directViewWithFiles(ctx context.Context, dm message.Direct) map[string]any {
	v := directView(dm)
	if atts := s.attachmentsOf(ctx, &dm); len(atts) > 0 && dm.DeletedAt.IsZero() {
		v["attachments"] = atts
	}
	return v
}

// claimAttachments checks that every file belongs to `from`, was uploaded for
// `to` and is not in a message yet; the caller links them once the message exists.
func (s *Service) claimAttachments(ctx context.Context, from, to identity.ID, ids []string) ([]directAttachment, error) {
	if len(ids) > maxDirectAttachments {
		return nil, errs.InvalidArgument("a message can carry up to 10 files")
	}
	rows := make([]directAttachment, 0, len(ids))
	seen := map[string]bool{}
	for _, id := range ids {
		var row directAttachment
		if seen[id] || s.R.GetString(ctx, "direct_attachments", id, &row) != nil {
			return nil, errs.InvalidArgument("one of the files is not there any more; attach it again")
		}
		seen[id] = true
		if row.OwnerID != from.String() || row.PeerID != to.String() || row.MessageID != "" {
			return nil, errs.New(errs.CodePermission, "that file can't be sent here")
		}
		rows = append(rows, row)
	}
	return rows, nil
}

// linkAttachments ties the files to the message they went with.
func (s *Service) linkAttachments(ctx context.Context, rows []directAttachment, messageID string) {
	for _, r := range rows {
		r.MessageID = messageID
		_ = s.R.DB.Update(ctx, "direct_attachments", r.ID, &r)
	}
}

// dropMessageFiles deletes the files of a message taken back, giving the storage back.
func (s *Service) dropMessageFiles(ctx context.Context, dm *message.Direct) {
	for _, id := range attachmentIDs(dm) {
		var row directAttachment
		if s.R.GetString(ctx, "direct_attachments", id, &row) == nil {
			s.dropAttachment(ctx, row)
		}
	}
	dm.AttachmentIDs = ""
}

// attachmentLabel is what a notification or preview says for a message with no
// text: the kind of its first file.
func (s *Service) attachmentLabel(ctx context.Context, dm *message.Direct) string {
	ids := attachmentIDs(dm)
	if len(ids) == 0 {
		return ""
	}
	var row directAttachment
	if s.R.GetString(ctx, "direct_attachments", ids[0], &row) != nil {
		return "File"
	}
	switch {
	case strings.HasPrefix(row.Mime, "image/"):
		return "Photo"
	case strings.HasPrefix(row.Mime, "video/"):
		return "Video"
	case strings.HasPrefix(row.Mime, "audio/"):
		return "Voice message"
	}
	return "File"
}

// canReadFile says whether `caller` may read a file: the one rule the file
// server uses for everything (spaces.CanReadFile: the owner, a public file, a
// member of the room it is in, or the person a chat file was sent to). When the
// rule cannot be asked, nobody gets the file.
func (s *Service) canReadFile(ctx context.Context, file, caller identity.ID) error {
	if s.FileAccess != nil {
		return s.FileAccess(ctx, file, caller)
	}
	if s.K == nil || caller.IsZero() {
		return errs.New(errs.CodePermission, "file is not shared with this account")
	}
	return bridge.Invoke(ctx, s.K, "spaces", "CanReadFile", []any{ctx, file, caller})
}

// directFileAccess is the chat part of that rule, for tests that have no spaces service.
func (s *Service) directFileAccess(ctx context.Context, file, caller identity.ID) error {
	var f filedata.File
	if err := s.R.Get(ctx, "files", file, &f); err != nil {
		return err
	}
	if f.OwnerID == caller {
		return nil
	}
	var row directAttachment
	if s.R.GetString(ctx, "direct_attachments", file.String(), &row) == nil && row.PeerID == caller.String() && row.MessageID != "" {
		return nil
	}
	// A kept copy is its keeper's own file record, so the owner check above covers it.
	return errs.New(errs.CodePermission, "file is not shared with this account")
}
