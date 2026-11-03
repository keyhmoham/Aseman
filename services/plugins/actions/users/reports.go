package users

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/crypto"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// chatReportsTable holds what people reported in their direct messages.
const chatReportsTable = "direct_reports"

// reportReasons are what a person can report a message or a chat for.
var reportReasons = map[string]bool{"spam": true, "harassment": true, "inappropriate": true, "scam": true, "other": true}

// chatReport is one report: who reported whom, about one message or the whole
// chat, why, and what the admin did. Evidence is the reported message(s) as
// they were when reported, encrypted like the messages themselves, so a
// later edit or delete does not erase what the admin needs to judge.
type chatReport struct {
	ID         string      `db:"id" json:"id"`
	ReporterID identity.ID `db:"reporter_id" json:"reporter_id"`
	PeerID     identity.ID `db:"peer_id" json:"peer_id"`
	MessageID  string      `db:"message_id" json:"message_id,omitempty"`
	Kind       string      `db:"kind" json:"kind"`
	Reason     string      `db:"reason" json:"reason"`
	Note       string      `db:"note" json:"note,omitempty"`
	Evidence   string      `db:"evidence" json:"-"`
	Status     string      `db:"status" json:"status"`
	ResolvedBy string      `db:"resolved_by" json:"resolved_by,omitempty"`
	CreatedAt  time.Time   `db:"created_at" json:"created_at"`
	ResolvedAt time.Time   `db:"resolved_at" json:"-"`
}

func reportContext(id string) string { return "users/report/v1/" + id }

// reportEvidence is what was reported: the one message, or the chat's last
// messages the reporter could see.
func (s *Service) reportEvidence(ctx context.Context, me, peer identity.ID, messageID string) ([]map[string]any, error) {
	if messageID != "" {
		id, err := identity.Parse(messageID)
		if err != nil {
			return nil, err
		}
		dm, err := s.getDirect(ctx, id)
		if err != nil {
			return nil, errs.InvalidArgument("that message is not there")
		}
		if !(dm.From == me && dm.To == peer || dm.From == peer && dm.To == me) {
			return nil, errs.New(errs.CodePermission, "not a message of your conversation")
		}
		return []map[string]any{directView(*dm)}, nil
	}
	var a, b []message.Direct
	if err := s.R.List(ctx, "directs", database.Filter{Equal: map[string]any{"from_id": me.String(), "to_id": peer.String()}, OrderBy: "created_at", Asc: false, Limit: 30}, &a); err != nil {
		return nil, err
	}
	if err := s.R.List(ctx, "directs", database.Filter{Equal: map[string]any{"from_id": peer.String(), "to_id": me.String()}, OrderBy: "created_at", Asc: false, Limit: 30}, &b); err != nil {
		return nil, err
	}
	all := append(a, b...)
	sort.Slice(all, func(i, j int) bool { return all[i].CreatedAt.Before(all[j].CreatedAt) })
	if len(all) > 30 {
		all = all[len(all)-30:]
	}
	out := make([]map[string]any, 0, len(all))
	for i := range all {
		s.openDirect(&all[i])
		out = append(out, directView(all[i]))
	}
	return out, nil
}

func (s *Service) dmReport(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Peer      string `json:"peer"`
		MessageID string `json:"message_id"`
		Reason    string `json:"reason"`
		Note      string `json:"note"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	peer, err := identity.Parse(in.Peer)
	if err != nil {
		return nil, err
	}
	if peer == req.Caller.ID {
		return nil, errs.InvalidArgument("you cannot report yourself")
	}
	if !reportReasons[in.Reason] {
		return nil, errs.InvalidArgument("pick a reason: spam, harassment, inappropriate, scam or other")
	}
	evidence, err := s.reportEvidence(ctx, req.Caller.ID, peer, in.MessageID)
	if err != nil {
		return nil, err
	}
	nid, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	id := nid.String()
	raw, _ := json.Marshal(evidence)
	sealed, err := crypto.SealSecret(string(raw), s.K.Env()["node_private_key"], reportContext(id))
	if err != nil {
		return nil, errs.New(errs.CodeUnavailable, "reports are unavailable on this node")
	}
	kind := "chat"
	if in.MessageID != "" {
		kind = "message"
	}
	note := strings.TrimSpace(in.Note)
	if len([]rune(note)) > 1000 {
		note = string([]rune(note)[:1000])
	}
	r := &chatReport{ID: id, ReporterID: req.Caller.ID, PeerID: peer, MessageID: in.MessageID, Kind: kind, Reason: in.Reason,
		Note: note, Evidence: sealed, Status: "open", CreatedAt: time.Now().UTC()}
	if err := s.R.DB.Create(ctx, chatReportsTable, id, r); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "id": id})
}

func (s *Service) adminChatReports(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var in struct {
		Status string `json:"status"`
	}
	_ = helper.Decode(req, &in)
	var rows []chatReport
	if err := s.R.List(ctx, chatReportsTable, database.Filter{OrderBy: "created_at", Asc: false, Limit: 500}, &rows); err != nil {
		return nil, err
	}
	out := []map[string]any{}
	open := 0
	for _, r := range rows {
		if r.Status == "open" {
			open++
		}
		if in.Status != "" && in.Status != "all" && r.Status != in.Status {
			continue
		}
		var evidence []map[string]any
		if plain, err := crypto.OpenSecret(r.Evidence, s.K.Env()["node_private_key"], reportContext(r.ID)); err == nil {
			_ = json.Unmarshal([]byte(plain), &evidence)
		}
		v := map[string]any{"id": r.ID, "kind": r.Kind, "reason": r.Reason, "note": r.Note, "status": r.Status, "created_at": r.CreatedAt,
			"message_id": r.MessageID, "reporter": s.publicRef(ctx, req.Caller.ID, r.ReporterID), "reported": s.publicRef(ctx, req.Caller.ID, r.PeerID),
			"evidence": evidence}
		if !r.ResolvedAt.IsZero() {
			v["resolved_at"], v["resolved_by"] = r.ResolvedAt, r.ResolvedBy
		}
		out = append(out, v)
	}
	return helper.JSON(map[string]any{"reports": out, "open": open})
}

func (s *Service) adminChatReportResolve(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var in struct {
		ID     string `json:"id"`
		Status string `json:"status"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if in.Status != "resolved" && in.Status != "dismissed" && in.Status != "open" {
		return nil, errs.InvalidArgument("status must be resolved, dismissed or open")
	}
	var r chatReport
	if err := s.R.GetString(ctx, chatReportsTable, in.ID, &r); err != nil {
		return nil, err
	}
	r.Status = in.Status
	if in.Status == "open" {
		r.ResolvedAt, r.ResolvedBy = time.Time{}, ""
	} else {
		r.ResolvedAt, r.ResolvedBy = time.Now().UTC(), req.Caller.ID.String()
	}
	if err := s.R.DB.Update(ctx, chatReportsTable, r.ID, &r); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}

func reportActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "users", Name: "dm_report", Summary: "Report a direct message or chat to the node's admins", Handler: s.dmReport},
		helper.Action{Namespace: "users", Name: "admin_chat_reports", Summary: "Admin: reported direct messages and chats", Handler: s.adminChatReports},
		helper.Action{Namespace: "users", Name: "admin_chat_report_resolve", Summary: "Admin: resolve, dismiss or reopen a chat report", Handler: s.adminChatReportResolve},
	}
}
