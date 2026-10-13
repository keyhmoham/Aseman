package spaces

import (
	"bytes"
	"context"
	"image"
	"image/jpeg"
	"io"
	"math"
	"mime"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	"github.com/tradera/tradera/plugins/actions/spaces/models/filedata"
	"github.com/tradera/tradera/plugins/actions/spaces/models/membership"
	"github.com/tradera/tradera/plugins/actions/spaces/models/permission"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// maxFileSize caps a single upload at 64MB (photos, gifs, audio, voice, short
// videos and documents all fit comfortably; anything bigger should be streamed).
const maxFileSize = 64 << 20 // 64 MiB

// maxExtractChars bounds how much text content is pulled out of an attached
// document for an agent's inline context (the file_read tool returns the rest).
const maxExtractChars = 12000

// maxImageDim caps the largest edge of an image embedded as multimodal input.
const maxImageDim = 1024

// contentPath returns the relative URL that streams a file's raw bytes with the
// correct Content-Type so media (images, gifs, audio, video) can be previewed
// straight from a <img>/player without downloading the whole base64 payload.
func contentPath(id identity.ID) string {
	return "/v1/files/" + id.String() + "/content"
}

// GetFile loads a file record by id.
func (s *Service) GetFile(ctx context.Context, id identity.ID) (*filedata.File, error) {
	f := &filedata.File{}
	if err := s.R.Get(ctx, "files", id, f); err != nil {
		return nil, err
	}
	return f, nil
}

// enrichMembers converts membership rows into their public wire form, resolving
// each member account's handle and kind so clients can show names in member
// lists / in-space user search.
func (s *Service) enrichMembers(ctx context.Context, mems []membership.Membership) []map[string]any {
	out := make([]map[string]any, 0, len(mems))
	people := s.participants()
	for i := range mems {
		m := map[string]any{
			"id":        mems[i].ID.String(),
			"member_id": mems[i].MemberID.String(),
			"space_id":  mems[i].SpaceID.String(),
			"room_id":   mems[i].RoomID.String(),
			"role":      string(mems[i].Role),
			"joined_at": mems[i].JoinedAt,
		}
		var acc account.Account
		if s.R.Get(ctx, "accounts", mems[i].MemberID, &acc) == nil {
			m["handle"] = acc.Handle
			m["kind"] = string(acc.Kind)
			m["status"] = acc.Status
		}
		who := people.get(ctx, mems[i].MemberID)
		for _, key := range []string{"display_name", "avatar", "bot_id"} {
			if v, ok := who[key]; ok {
				m[key] = v
			}
		}
		out = append(out, m)
	}
	return out
}

// MessageSearch lists room messages across a whole space matching a body
// substring, newest first, with offset pagination (Explore → in-space messages).
func (s *Service) MessageSearch(ctx context.Context, spaceID identity.ID, query string, limit, offset int) ([]message.Message, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if offset < 0 {
		offset = 0
	}
	var all []message.Message
	if err := s.R.List(ctx, "messages", database.Filter{
		Equal: map[string]any{"space_id": spaceID.String()}, OrderBy: "created_at", Asc: false,
	}, &all); err != nil {
		return nil, err
	}
	q := strings.ToLower(strings.TrimSpace(query))
	var out []message.Message
	for _, m := range all {
		if q != "" && !strings.Contains(strings.ToLower(m.Body), q) {
			continue
		}
		out = append(out, m)
	}
	if offset > len(out) {
		offset = len(out)
	}
	out = out[offset:]
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// CanReadFile verifies the caller may read the space/room a file lives in.
func (s *Service) CanReadFile(ctx context.Context, fileID identity.ID, caller identity.ID) error {
	f, err := s.GetFile(ctx, fileID)
	if err != nil {
		return err
	}
	if f.Public || f.OwnerID == caller {
		return nil
	}
	if f.SpaceID.IsZero() {
		var memberships []membership.Membership
		if e := s.R.List(ctx, "memberships", database.Filter{Equal: map[string]any{"member_id": caller.String()}}, &memberships); e != nil {
			return e
		}
		spaces := []any{}
		for _, m := range memberships {
			spaces = append(spaces, m.SpaceID.String())
		}
		if len(spaces) == 0 {
			return errs.Permission("file is not shared with this account")
		}
		var messages []message.Message
		if e := s.R.List(ctx, "messages", database.Filter{In: map[string][]any{"space_id": spaces}}, &messages); e != nil {
			return e
		}
		for _, m := range messages {
			for _, ref := range m.ParseAttachments() {
				if ref == fileID.String() && s.Can(ctx, m.SpaceID, m.RoomID, caller, permission.RoomRead) == nil {
					return nil
				}
			}
		}
		return errs.Permission("file is not shared with this account")
	}
	return s.Can(ctx, f.SpaceID, f.RoomID, caller, permission.RoomRead)
}

// senderHandle resolves an account id onto its handle (bot accounts use their
// bot name) so tradera's conversation context is readable.
func (s *Service) senderHandle(ctx context.Context, accID identity.ID) (string, bool) {
	var acc account.Account
	if err := s.R.Get(ctx, "accounts", accID, &acc); err == nil && acc.Handle != "" {
		return acc.Handle, true
	}
	return "", false
}

// ReadFileBytes loads the full binary payload of a file.
func (s *Service) ReadFileBytes(ctx context.Context, f *filedata.File) ([]byte, error) {
	fs := s.K.FS()
	if fs == nil {
		return nil, errs.New(errs.CodeUnavailable, "no filesystem adapter active")
	}
	rc, err := fs.Get(ctx, f.StorageKey)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(rc)
}

// fileMeta renders the public JSON representation of a file: identity + storage
// metadata plus the streaming content_url used for previews and downloads.
func (s *Service) fileMeta(ctx context.Context, f *filedata.File) map[string]any {
	return map[string]any{
		"file_id":     f.ID.String(),
		"id":          f.ID.String(),
		"owner_id":    f.OwnerID.String(),
		"space_id":    f.SpaceID.String(),
		"room_id":     f.RoomID.String(),
		"name":        f.Name,
		"mime":        f.Mime,
		"size":        f.Size,
		"public":      f.Public,
		"content_url": contentPath(f.ID),
		"created_at":  f.CreatedAt,
	}
}

// enrichMessages converts stored messages into their wire representation,
// resolving each message's attachment file ids into rich metadata so clients
// can render previews (photo, gif, video, audio, voice, document) without a
// separate round trip per file.
func (s *Service) enrichMessages(ctx context.Context, msgs []message.Message) []map[string]any {
	out := make([]map[string]any, 0, len(msgs))
	people := s.participants()
	for i := range msgs {
		m := messageToMap(&msgs[i])
		m["sender"] = people.get(ctx, msgs[i].SenderID)
		ids := msgs[i].ParseAttachments()
		atts := make([]map[string]any, 0, len(ids))
		for _, ref := range ids {
			fid, err := identity.Parse(ref)
			if err != nil {
				continue
			}
			f, err := s.GetFile(ctx, fid)
			if err != nil {
				continue
			}
			atts = append(atts, s.fileMeta(ctx, f))
		}
		m["attachments"] = atts
		out = append(out, m)
	}
	return out
}

// messageToMap serializes a message to its JSON map form.
func messageToMap(m *message.Message) map[string]any {
	return map[string]any{
		"id":             m.ID.String(),
		"space_id":       m.SpaceID.String(),
		"room_id":        m.RoomID.String(),
		"sender_id":      m.SenderID.String(),
		"body":           m.Body,
		"kind":           m.Kind,
		"mentions":       m.ParseMentions(),
		"attachment_ids": m.ParseAttachments(),
		"reply_to":       m.ReplyTo,
		"created_at":     m.CreatedAt,
		"updated_at":     m.UpdatedAt,
	}
}

// UploadFile stores a file into a space/room on behalf of [caller] and returns
// its metadata. This is the service-level upload used by both the HTTP action
// and the agent file_send/file_upload tools.
func (s *Service) UploadFile(ctx context.Context, caller, spaceID, roomID identity.ID, name, mimeType string, data []byte) (*filedata.File, error) {
	name = sanitizeName(name)
	if name == "" {
		return nil, errs.InvalidArgument("file name required")
	}
	if len(data) == 0 {
		return nil, errs.InvalidArgument("file data required")
	}
	if len(data) > maxFileSize {
		return nil, errs.InvalidArgument("file exceeds maximum size of 64MB")
	}
	if mimeType == "" {
		mimeType = sniffMime(name, data)
	}
	fs := s.K.FS()
	if fs == nil {
		return nil, errs.New(errs.CodeUnavailable, "no filesystem adapter active")
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	if err := fs.Put(ctx, id.String(), bytes.NewReader(data), int64(len(data)), mimeType); err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	file := &filedata.File{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		OwnerID: caller, SpaceID: spaceID, RoomID: roomID, Name: name,
		Mime: mimeType, Size: int64(len(data)), StorageKey: id.String()}
	if err := s.R.CreateID(ctx, "files", id, file); err != nil {
		return nil, err
	}
	return file, nil
}

// sanitizeName strips path separators and control characters from a user
// supplied file name so it is safe to echo back in headers and URLs.
func sanitizeName(name string) string {
	name = strings.TrimSpace(name)
	name = strings.ReplaceAll(name, "/", "_")
	name = strings.ReplaceAll(name, "\\", "_")
	name = strings.ReplaceAll(name, "\x00", "")
	name = strings.TrimSpace(name)
	if len(name) > 255 {
		name = name[:255]
	}
	return name
}

// sniffMime guesses a MIME type from the file extension, falling back to
// application/octet-stream.
func sniffMime(name string, data []byte) string {
	if ct := mime.TypeByExtension(strings.ToLower(filepath.Ext(name))); ct != "" {
		return ct
	}
	// A tiny sniff for the most common media signatures so uploads without an
	// extension still preview correctly.
	switch {
	case len(data) > 3 && data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46:
		return "image/gif"
	case len(data) > 8 && string(data[0:8]) == "\x89PNG\r\n\x1a\n":
		return "image/png"
	case len(data) > 2 && data[0] == 0xFF && data[1] == 0xD8:
		return "image/jpeg"
	case len(data) > 11 && string(data[0:4]) == "RIFF" && string(data[8:12]) == "WEBP":
		return "image/webp"
	}
	return http.DetectContentType(data)
}

// ResolveAttachments turns a list of file ids into the VM-facing attachment
// descriptors an agent receives for a chat message, authorizing the caller to
// read each file first.
//
// The descriptors are deliberately TAG-ONLY: the heavy payload (extracted text
// content, downscaled image pixels) is NOT loaded here, because embedding it
// into every agent's context — and re-sending it every tool turn — burns tokens
// even when the agent never uses the file. Agents see a compact tag (name, mime,
// size, content url) and fetch the actual content on demand with the file_read
// tool (which returns text content, or the image itself as multimodal input), so
// large multimodal data only enters context when an agent actually needs it.
func (s *Service) ResolveAttachments(ctx context.Context, caller identity.ID, ids []string) ([]vmm.FileAttachment, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	out := make([]vmm.FileAttachment, 0, len(ids))
	for _, ref := range ids {
		fid, err := identity.Parse(ref)
		if err != nil {
			return nil, errs.InvalidArgument("invalid attachment id")
		}
		f, err := s.GetFile(ctx, fid)
		if err != nil {
			return nil, err
		}
		if err := s.Can(ctx, f.SpaceID, f.RoomID, caller, permission.RoomRead); err != nil {
			return nil, err
		}
		out = append(out, vmm.FileAttachment{
			ID:   f.ID.String(),
			Name: f.Name,
			Mime: f.Mime,
			Size: f.Size,
			URL:  contentPath(f.ID),
		})
	}
	return out, nil
}

// imageDataForContent downscales an image to a bounded square-ish JPEG so it can
// be embedded as a data URL in the agent's multimodal prompt without exploding
// the token budget. Formats the standard library cannot decode (e.g. webp) fall
// back to the raw bytes when they are small enough to embed.
func imageDataForContent(mimeType string, data []byte) ([]byte, string) {
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		if len(data) <= 1<<20 { // ≤1MiB raw fallback
			return data, mimeType
		}
		return nil, ""
	}
	bounds := img.Bounds()
	w, h := bounds.Dx(), bounds.Dy()
	if w > maxImageDim || h > maxImageDim {
		scale := float64(maxImageDim) / math.Max(float64(w), float64(h))
		nw := math.Max(1, float64(w)*scale)
		nh := math.Max(1, float64(h)*scale)
		img = scaleNearest(img, int(nw), int(nh))
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 82}); err != nil {
		return nil, ""
	}
	return buf.Bytes(), "image/jpeg"
}

// scaleNearest downsamples an image with a simple nearest-neighbour mapping
// (the deprecated image/draw Scaler API was removed in recent Go toolchains).
func scaleNearest(src image.Image, nw, nh int) image.Image {
	sb := src.Bounds()
	sw, sh := sb.Dx(), sb.Dy()
	if nw <= 0 || nh <= 0 || (nw == sw && nh == sh) {
		return src
	}
	dst := image.NewRGBA(image.Rect(0, 0, nw, nh))
	for y := 0; y < nh; y++ {
		sy := sb.Min.Y + y*sh/nh
		for x := 0; x < nw; x++ {
			sx := sb.Min.X + x*sw/nw
			dst.Set(x, y, src.At(sx, sy))
		}
	}
	return dst
}

// isTextFile reports whether a file's content can be extracted and included as
// text for an agent (documents, code, transcripts, configs, ...). Binary/media
// files (images, gifs, audio, voice, video, pdfs) are excluded.
func isTextFile(mimeType, name string) bool {
	mt := strings.ToLower(mimeType)
	ext := strings.ToLower(filepath.Ext(name))
	switch {
	case strings.HasPrefix(mt, "text/"), mt == "application/json",
		strings.HasPrefix(mt, "application/xml"), mt == "application/yaml",
		mt == "application/x-yaml", mt == "application/javascript",
		mt == "application/x-javascript", mt == "application/x-sh",
		mt == "application/sql", mt == "application/csv":
		return true
	}
	switch ext {
	case ".txt", ".md", ".markdown", ".json", ".jsonl", ".csv", ".tsv",
		".xml", ".yaml", ".yml", ".log", ".env", ".ini", ".conf", ".cfg",
		".sh", ".bash", ".zsh", ".ps1", ".bat", ".cmd", ".py", ".js", ".mjs",
		".ts", ".jsx", ".tsx", ".html", ".htm", ".css", ".scss", ".less",
		".sql", ".go", ".rs", ".c", ".h", ".cpp", ".hpp", ".java", ".kt",
		".rb", ".php", ".lua", ".pl", ".r", ".dart", ".swift", ".cs", ".toml":
		return true
	}
	return false
}

// truncateText bounds extracted file content to [n] characters, keeping a
// marker when the document was truncated.
func truncateText(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "\n…[truncated]"
}
