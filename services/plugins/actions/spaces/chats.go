package spaces

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/jsonpatch"
	"github.com/tradera/tradera/plugins/actions/message/models/message"
	"github.com/tradera/tradera/plugins/actions/spaces/models/permission"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
)

// What a person does with their chats beyond writing in them: change or take
// back what they wrote, pin a chat to the top of the messenger, delete a
// direct chat for themselves, block the other side of one, say they are
// typing and report what someone wrote to the node's admins. It all works on
// rooms (a direct chat is a one-room space), so a project room gets the same.
//
// Each person's own view of a chat (pinned, cleared, blocked) is kept in the
// space's metadata next to their read cursor (chat_seen), so every device
// agrees on it.

func pinPath(accountID, roomID identity.ID) string {
	return "chat_pins/" + accountID.String() + "/" + roomID.String()
}
func clearedPath(accountID identity.ID) string { return "chat_cleared/" + accountID.String() }
func blockedPath(accountID identity.ID) string { return "chat_blocked/" + accountID.String() }

// chatTree is a space's metadata tree (empty when it has none).
func (s *Service) chatTree(ctx context.Context, spaceID identity.ID) map[string]any {
	if s.M == nil {
		return map[string]any{}
	}
	rec, err := s.M.Get(ctx, spaceID)
	if err != nil || rec == nil || rec.Tree == nil {
		return map[string]any{}
	}
	return rec.Tree
}

func treeTime(tree map[string]any, keys ...string) time.Time {
	var cur any = tree
	for _, k := range keys {
		m, _ := cur.(map[string]any)
		cur = m[k]
	}
	text, _ := cur.(string)
	at, err := time.Parse(time.RFC3339Nano, text)
	if err != nil {
		return time.Time{}
	}
	return at
}

// pinnedIn is when the account pinned a room to the top of its chats (zero: not pinned).
func pinnedIn(tree map[string]any, accountID, roomID identity.ID) time.Time {
	return treeTime(tree, "chat_pins", accountID.String(), roomID.String())
}

// clearedIn is when the account deleted the conversation for itself: it sees
// only what came after.
func clearedIn(tree map[string]any, accountID identity.ID) time.Time {
	return treeTime(tree, "chat_cleared", accountID.String())
}

func blockedIn(tree map[string]any, accountID identity.ID) bool {
	m, _ := tree["chat_blocked"].(map[string]any)
	v, _ := m[accountID.String()].(bool)
	return v
}

// directBlock reports whether a message cannot go between the two sides of a
// direct chat because either blocked the other; byMe says the sender did.
func (s *Service) directBlock(ctx context.Context, spaceID, sender identity.ID) (blocked, byMe bool) {
	sp, err := s.GetSpace(ctx, spaceID)
	if err != nil || !sp.Direct {
		return false, false
	}
	tree := s.chatTree(ctx, spaceID)
	if blockedIn(tree, sender) {
		return true, true
	}
	for _, peer := range s.directPeers(ctx, spaceID, sender) {
		if blockedIn(tree, peer) {
			return true, false
		}
	}
	return false, false
}

// blockError is what a sender hears when a direct chat is blocked.
func blockError(byMe bool) error {
	if byMe {
		return errs.Permission("You blocked this chat. Unblock it to send a message.")
	}
	return errs.Permission("You can't message this person.")
}

// DirectBlocked reports whether two accounts' direct chat is blocked either
// way (false when they have none). users.dm_send asks before it delivers.
func (s *Service) DirectBlocked(ctx context.Context, from, to identity.ID) (bool, error) {
	sp := s.findDirect(ctx, directKey(from, s.botAccountOf(ctx, to)))
	if sp == nil {
		return false, nil
	}
	blocked, _ := s.directBlock(ctx, sp.ID, from)
	return blocked, nil
}

// ── typing ──────────────────────────────────────────────────────────────────

// typingFor is how long "typing" lasts without being said again.
const typingFor = 6 * time.Second

// typing is who is typing in which room, until when. It lives in memory: it
// is only true for a few seconds.
var typing = struct {
	sync.Mutex
	until map[string]map[string]time.Time // room → account → until
}{until: map[string]map[string]time.Time{}}

func setTyping(roomID, accountID identity.ID, on bool) {
	typing.Lock()
	defer typing.Unlock()
	room := typing.until[roomID.String()]
	if !on {
		delete(room, accountID.String())
		return
	}
	if room == nil {
		room = map[string]time.Time{}
		typing.until[roomID.String()] = room
	}
	room[accountID.String()] = time.Now().Add(typingFor)
}

// typingIn lists who is typing in a room now, except the caller.
func typingIn(roomID, caller identity.ID) []identity.ID {
	typing.Lock()
	defer typing.Unlock()
	now := time.Now()
	var out []identity.ID
	for who, until := range typing.until[roomID.String()] {
		if now.After(until) {
			delete(typing.until[roomID.String()], who)
			continue
		}
		if id, err := identity.Parse(who); err == nil && id != caller {
			out = append(out, id)
		}
	}
	return out
}

// ── reports ─────────────────────────────────────────────────────────────────

// Report statuses.
const (
	reportOpen      = "open"
	reportResolved  = "resolved"
	reportDismissed = "dismissed"
)

var reportReasons = map[string]bool{"spam": true, "harassment": true, "abuse": true, "scam": true, "inappropriate": true, "other": true}

// reportEvidence is how many messages before a reported one (or at the end of
// a reported chat) the admins see with the report.
const reportEvidence = 20

// ChatReport is something a person reported in a room to the node's admins,
// with a copy of what was written as it was then.
type ChatReport struct {
	entity.Entity
	ReporterID identity.ID `db:"reporter_id" json:"reporter_id"`
	SpaceID    identity.ID `db:"space_id" json:"space_id"`
	RoomID     identity.ID `db:"room_id" json:"room_id"`
	// MessageID is the reported message; empty when the whole chat is.
	MessageID string `db:"message_id" json:"message_id,omitempty"`
	// AccusedID is who wrote the reported message, or the other side of a
	// reported direct chat.
	AccusedID string `db:"accused_id" json:"accused_id,omitempty"`
	Reason    string `db:"reason" json:"reason"`
	Note      string `db:"note" json:"note,omitempty"`
	// Evidence is a JSON list of the messages copied with the report.
	Evidence   string    `db:"evidence" json:"-"`
	Status     string    `db:"status" json:"status"`
	ResolvedBy string    `db:"resolved_by" json:"resolved_by,omitempty"`
	ResolvedAt time.Time `db:"resolved_at" json:"resolved_at,omitempty"`
}

// ── actions ─────────────────────────────────────────────────────────────────

func chatActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "spaces", Name: "message_edit", Summary: "Change the text of a message you sent", Handler: s.messageEdit},
		helper.Action{Namespace: "spaces", Name: "typing_set", Summary: "Say you are typing in a room (or stopped)", Handler: s.typingSet},
		helper.Action{Namespace: "spaces", Name: "chat_pin", Summary: "Pin a chat to the top of your chats, or unpin it", Handler: s.chatPin},
		helper.Action{Namespace: "spaces", Name: "chat_clear", Summary: "Delete a direct chat for yourself: you see only what comes after", Handler: s.chatClear},
		helper.Action{Namespace: "spaces", Name: "direct_block", Summary: "Block or unblock the other side of a direct chat: neither of you can write in it", Handler: s.directBlockSet},
		helper.Action{Namespace: "spaces", Name: "message_report", Summary: "Report a message or a chat to the node's admins", Handler: s.messageReport},
		helper.Action{Namespace: "spaces", Name: "admin_chat_reports", Summary: "Admin: what people reported in chats", Handler: s.adminChatReports},
		helper.Action{Namespace: "spaces", Name: "admin_chat_report_resolve", Summary: "Admin: resolve, dismiss or reopen a chat report", Handler: s.adminChatReportResolve},
	}
}

func (s *Service) messageEdit(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Message string `json:"message"`
		Body    string `json:"body"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	body := strings.TrimSpace(in.Body)
	if body == "" {
		return nil, errs.InvalidArgument("body required: delete the message instead")
	}
	msgID, err := identity.Parse(in.Message)
	if err != nil {
		return nil, errs.InvalidArgument("invalid message id")
	}
	msg := &message.Message{}
	if err := s.R.Get(ctx, "messages", msgID, msg); err != nil {
		return nil, err
	}
	if msg.SenderID != req.Caller.ID {
		return nil, errs.Permission("you can only change your own messages")
	}
	if msg.Kind != "" && msg.Kind != message.KindMessage {
		return nil, errs.InvalidArgument("only a conversation message can be changed")
	}
	if err := s.Can(ctx, msg.SpaceID, msg.RoomID, req.Caller.ID, permission.RoomSend); err != nil {
		return nil, err
	}
	if blocked, byMe := s.directBlock(ctx, msg.SpaceID, req.Caller.ID); blocked {
		return nil, blockError(byMe)
	}
	if body == msg.Body {
		return helper.JSON(map[string]any{"ok": true, "message": messageToMap(msg)})
	}
	now := time.Now().UTC()
	msg.Body, msg.EditedAt, msg.UpdatedAt = body, now, now
	if err := s.R.Update(ctx, "messages", msgID, msg); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "message": messageToMap(msg)})
}

func (s *Service) typingSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Space  string `json:"space"`
		Room   string `json:"room"`
		Typing *bool  `json:"typing,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	roomID, err := identity.Parse(in.Room)
	if err != nil {
		return nil, errs.InvalidArgument("invalid room id")
	}
	if err := s.Can(ctx, spID, roomID, req.Caller.ID, permission.RoomSend); err != nil {
		return nil, err
	}
	on := in.Typing == nil || *in.Typing
	if blocked, _ := s.directBlock(ctx, spID, req.Caller.ID); blocked {
		on = false
	}
	setTyping(roomID, req.Caller.ID, on)
	return helper.JSON(map[string]any{"ok": true})
}

func (s *Service) chatPin(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Space  string `json:"space"`
		Room   string `json:"room"`
		Pinned *bool  `json:"pinned,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, _ := identity.Parse(in.Space)
	roomID, err := identity.Parse(in.Room)
	if err != nil {
		return nil, errs.InvalidArgument("invalid room id")
	}
	if err := s.Can(ctx, spID, roomID, req.Caller.ID, permission.RoomRead); err != nil {
		return nil, err
	}
	pinned := in.Pinned == nil || *in.Pinned
	op := jsonpatch.Op{Op: "remove", Path: pinPath(req.Caller.ID, roomID)}
	now := time.Now().UTC()
	if pinned {
		op = jsonpatch.Op{Op: "set", Path: pinPath(req.Caller.ID, roomID), Value: now.Format(time.RFC3339Nano)}
	} else if pinnedIn(s.chatTree(ctx, spID), req.Caller.ID, roomID).IsZero() {
		return helper.JSON(map[string]any{"ok": true, "pinned": false})
	}
	if err := s.M.Patch(ctx, spID, jsonpatch.Patch{op}); err != nil {
		return nil, err
	}
	out := map[string]any{"ok": true, "pinned": pinned}
	if pinned {
		out["pinned_at"] = now
	}
	return helper.JSON(out)
}

// directSpaceOf checks that the caller is in a direct chat's space.
func (s *Service) directSpaceOf(ctx context.Context, raw string, caller identity.ID) (identity.ID, error) {
	spID, err := identity.Parse(raw)
	if err != nil {
		return identity.ID{}, errs.InvalidArgument("invalid space id")
	}
	sp, err := s.GetSpace(ctx, spID)
	if err != nil {
		return identity.ID{}, err
	}
	if !sp.Direct {
		return identity.ID{}, errs.InvalidArgument("only a direct chat can be")
	}
	if _, err := s.SpaceMembership(ctx, spID, caller); err != nil {
		return identity.ID{}, errs.Permission("not a member of this chat")
	}
	return spID, nil
}

func (s *Service) chatClear(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Space string `json:"space"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, err := s.directSpaceOf(ctx, in.Space, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	patch := jsonpatch.Patch{{Op: "set", Path: clearedPath(req.Caller.ID), Value: now.Format(time.RFC3339Nano)}}
	if err := s.M.Patch(ctx, spID, patch); err != nil {
		return nil, err
	}
	// Nothing before now is unread any more.
	_, _ = s.MarkSeen(ctx, req.Caller.ID, spID, now)
	return helper.JSON(map[string]any{"ok": true, "cleared_at": now})
}

func (s *Service) directBlockSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Space   string `json:"space"`
		Blocked *bool  `json:"blocked,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	spID, err := s.directSpaceOf(ctx, in.Space, req.Caller.ID)
	if err != nil {
		return nil, err
	}
	if len(s.directPeers(ctx, spID, req.Caller.ID)) == 0 {
		return nil, errs.InvalidArgument("there is no one to block in your saved messages")
	}
	blocked := in.Blocked == nil || *in.Blocked
	op := jsonpatch.Op{Op: "set", Path: blockedPath(req.Caller.ID), Value: true}
	if !blocked {
		if !blockedIn(s.chatTree(ctx, spID), req.Caller.ID) {
			return helper.JSON(map[string]any{"ok": true, "blocked": false})
		}
		op = jsonpatch.Op{Op: "remove", Path: blockedPath(req.Caller.ID)}
	}
	if err := s.M.Patch(ctx, spID, jsonpatch.Patch{op}); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "blocked": blocked})
}

// evidenceOf copies the messages a report is about: the reported message and
// the ones before it, or the end of the chat, oldest first.
func (s *Service) evidenceOf(ctx context.Context, roomID identity.ID, upTo time.Time) []map[string]any {
	f := database.Filter{Equal: map[string]any{"room_id": roomID.String()}, In: map[string][]any{"kind": {"", message.KindMessage}},
		OrderBy: "created_at", Asc: false, Limit: reportEvidence + 1}
	if !upTo.IsZero() {
		f.LessThan = map[string]any{"created_at": upTo.Add(time.Millisecond)}
	}
	var msgs []message.Message
	if err := s.R.List(ctx, "messages", f, &msgs); err != nil {
		return nil
	}
	people := s.participants()
	out := make([]map[string]any, 0, len(msgs))
	for i := len(msgs) - 1; i >= 0; i-- {
		m := msgs[i]
		row := map[string]any{"id": m.ID.String(), "sender": people.get(ctx, m.SenderID), "body": m.Body,
			"attachments": len(m.ParseAttachments()), "created_at": m.CreatedAt}
		if !m.EditedAt.IsZero() {
			row["edited_at"] = m.EditedAt
		}
		out = append(out, row)
	}
	return out
}

func (s *Service) messageReport(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Space   string `json:"space"`
		Room    string `json:"room"`
		Message string `json:"message,omitempty"`
		Reason  string `json:"reason"`
		Note    string `json:"note,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	in.Reason = strings.ToLower(strings.TrimSpace(in.Reason))
	if !reportReasons[in.Reason] {
		return nil, errs.InvalidArgument("reason must be spam, harassment, abuse, scam, inappropriate or other")
	}
	if in.Note = strings.TrimSpace(in.Note); len([]rune(in.Note)) > 1000 {
		return nil, errs.InvalidArgument("the note is too long (1,000 characters at most)")
	}
	spID, _ := identity.Parse(in.Space)
	roomID, err := identity.Parse(in.Room)
	if err != nil {
		return nil, errs.InvalidArgument("invalid room id")
	}
	if err := s.Can(ctx, spID, roomID, req.Caller.ID, permission.RoomRead); err != nil {
		return nil, err
	}
	report := &ChatReport{ReporterID: req.Caller.ID, SpaceID: spID, RoomID: roomID, Reason: in.Reason, Note: in.Note, Status: reportOpen}
	var upTo time.Time
	if in.Message != "" {
		msgID, err := identity.Parse(in.Message)
		if err != nil {
			return nil, errs.InvalidArgument("invalid message id")
		}
		var msg message.Message
		if err := s.R.Get(ctx, "messages", msgID, &msg); err != nil || msg.RoomID != roomID {
			return nil, errs.NotFound("that message is not in this chat")
		}
		if msg.SenderID == req.Caller.ID {
			return nil, errs.InvalidArgument("you cannot report your own message")
		}
		report.MessageID, report.AccusedID, upTo = msg.ID.String(), msg.SenderID.String(), msg.CreatedAt
	} else if peers := s.directPeers(ctx, spID, req.Caller.ID); len(peers) > 0 {
		if sp, err := s.GetSpace(ctx, spID); err == nil && sp.Direct {
			report.AccusedID = peers[0].String()
		}
	}
	// One open report per person and message (or chat): reporting again
	// updates the reason instead of filing it twice.
	var existing []ChatReport
	_ = s.R.List(ctx, "chat_reports", database.Filter{Equal: map[string]any{
		"reporter_id": req.Caller.ID.String(), "room_id": roomID.String(), "message_id": report.MessageID, "status": reportOpen,
	}, Limit: 1}, &existing)
	evidence, _ := json.Marshal(s.evidenceOf(ctx, roomID, upTo))
	report.Evidence = string(evidence)
	now := time.Now().UTC()
	if len(existing) > 0 {
		report.Entity = existing[0].Entity
		report.UpdatedAt = now
		if err := s.R.Update(ctx, "chat_reports", report.ID, report); err != nil {
			return nil, err
		}
		return helper.JSON(map[string]any{"ok": true, "id": report.ID.String()})
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	report.Entity = entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}
	if err := s.R.CreateID(ctx, "chat_reports", id, report); err != nil {
		return nil, err
	}
	if s.L != nil {
		s.L.Info("chat reported", "report", id.String(), "reason", in.Reason)
	}
	return helper.JSON(map[string]any{"ok": true, "id": id.String()})
}

func (s *Service) adminChatReports(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	var in struct {
		Status string `json:"status,omitempty"` // open (default), resolved, dismissed or all
		Limit  int    `json:"limit,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if in.Limit <= 0 || in.Limit > 200 {
		in.Limit = 100
	}
	f := database.Filter{OrderBy: "created_at", Asc: false, Limit: in.Limit}
	switch in.Status {
	case "all":
	case "":
		f.Equal = map[string]any{"status": reportOpen}
	case reportOpen, reportResolved, reportDismissed:
		f.Equal = map[string]any{"status": in.Status}
	default:
		return nil, errs.InvalidArgument("status must be open, resolved, dismissed or all")
	}
	var rows []ChatReport
	if err := s.R.List(ctx, "chat_reports", f, &rows); err != nil {
		return nil, err
	}
	open, _ := s.R.Count(ctx, "chat_reports", database.Filter{Equal: map[string]any{"status": reportOpen}})
	people := s.participants()
	out := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		row := map[string]any{
			"id": r.ID.String(), "created_at": r.CreatedAt, "updated_at": r.UpdatedAt, "status": r.Status,
			"reason": r.Reason, "note": r.Note, "space_id": r.SpaceID.String(), "room_id": r.RoomID.String(),
			"message_id": r.MessageID, "reporter": people.get(ctx, r.ReporterID), "kind": "chat",
		}
		if r.MessageID != "" {
			row["kind"] = "message"
		}
		if id, err := identity.Parse(r.AccusedID); err == nil {
			row["accused"] = people.get(ctx, id)
		}
		if sp, err := s.GetSpace(ctx, r.SpaceID); err == nil {
			row["space_name"], row["direct"] = sp.Name, sp.Direct
		}
		var evidence []map[string]any
		_ = json.Unmarshal([]byte(r.Evidence), &evidence)
		row["evidence"] = evidence
		if r.ResolvedBy != "" {
			if id, err := identity.Parse(r.ResolvedBy); err == nil {
				row["resolved_by"] = people.get(ctx, id)
			}
			row["resolved_at"] = r.ResolvedAt
		}
		out = append(out, row)
	}
	return helper.JSON(map[string]any{"reports": out, "open": open})
}

func (s *Service) adminChatReportResolve(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	var in struct {
		ID     string `json:"id"`
		Status string `json:"status"` // resolved, dismissed or open (reopen)
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.ID)
	if err != nil {
		return nil, errs.InvalidArgument("invalid report id")
	}
	if in.Status != reportResolved && in.Status != reportDismissed && in.Status != reportOpen {
		return nil, errs.InvalidArgument("status must be resolved, dismissed or open")
	}
	var r ChatReport
	if err := s.R.Get(ctx, "chat_reports", id, &r); err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	r.Status, r.UpdatedAt = in.Status, now
	if in.Status == reportOpen {
		r.ResolvedBy, r.ResolvedAt = "", time.Time{}
	} else {
		r.ResolvedBy, r.ResolvedAt = req.Caller.ID.String(), now
	}
	if err := s.R.Update(ctx, "chat_reports", id, &r); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "status": r.Status})
}

// spaceAvatar is the picture a workspace was given, "" when it has none.
func (s *Service) spaceAvatar(ctx context.Context, spaceID identity.ID) string {
	return helper.TreeAvatar(s.chatTree(ctx, spaceID))
}
