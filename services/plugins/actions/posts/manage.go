package posts

import (
	"context"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/posts/models"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

const (
	reportOpen      = "open"
	reportResolved  = "resolved"
	reportDismissed = "dismissed"
)

// reportReasons are why a post can be reported, the same as a chat message.
var reportReasons = map[string]bool{"spam": true, "harassment": true, "abuse": true, "scam": true, "inappropriate": true, "other": true}

// Update changes the body of a post the caller wrote. A shared post keeps
// its original's words, so it cannot be edited.
func (s *Service) Update(ctx context.Context, caller, id identity.ID, body string) (*post.Post, error) {
	body = strings.TrimSpace(body)
	if body == "" {
		return nil, errs.InvalidArgument("post body required")
	}
	if len(body) > 4000 {
		return nil, errs.InvalidArgument("post body too long (max 4000)")
	}
	p, err := s.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	if p.AuthorID != caller {
		return nil, errs.Permission("only the author can edit a post")
	}
	if p.IsForward() {
		return nil, errs.InvalidArgument("a shared post cannot be edited")
	}
	if p.Body == body {
		return p, nil
	}
	now := time.Now().UTC()
	p.Body, p.EditedAt, p.UpdatedAt = body, now, now
	if err := s.R.Update(ctx, "posts", p.ID, p); err != nil {
		return nil, err
	}
	return p, nil
}

// Forward shares a post the caller can read into the global feed or, with
// spaceID, a workspace feed the caller is a member of. The shared post copies
// the original's body and media and names the original and its author;
// sharing a shared post shares its original.
func (s *Service) Forward(ctx context.Context, caller, spaceID, originalID identity.ID) (*post.Post, error) {
	orig, err := s.Get(ctx, originalID)
	if err != nil {
		return nil, err
	}
	if !orig.ParentID.IsZero() {
		return nil, errs.InvalidArgument("a comment cannot be shared")
	}
	if !s.visible(ctx, caller, orig, map[string]bool{}) {
		return nil, errs.Permission("not a member of the space")
	}
	if !spaceID.IsZero() {
		member, err := s.isMember(ctx, caller, spaceID)
		if err != nil {
			return nil, err
		}
		if !member {
			return nil, errs.Permission("not a member of the space")
		}
	}
	rootID, rootAuthor := orig.ID, orig.AuthorID
	if orig.IsForward() {
		rootID, rootAuthor = orig.ForwardOf, orig.ForwardAuthorID
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	p := &post.Post{
		Entity:   entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now},
		AuthorID: caller, SpaceID: spaceID,
		Body: orig.Body, Tags: orig.Tags, Media: orig.Media,
		LikedBy: "[]", ForwardOf: rootID, ForwardAuthorID: rootAuthor,
	}
	if p.Tags == "" {
		p.Tags = "[]"
	}
	if p.Media == "" {
		p.Media = "[]"
	}
	if err := s.R.CreateID(ctx, "posts", id, p); err != nil {
		return nil, err
	}
	s.L.Info("post shared", "post", id.String(), "original", rootID.String(), "author", caller.String())
	return p, nil
}

// Report files a post the caller can read with the node's admins. Reporting
// the same post again while the report is open updates its reason.
func (s *Service) Report(ctx context.Context, caller, id identity.ID, reason, note string) (*post.Report, error) {
	reason = strings.ToLower(strings.TrimSpace(reason))
	if !reportReasons[reason] {
		return nil, errs.InvalidArgument("reason must be spam, harassment, abuse, scam, inappropriate or other")
	}
	if note = strings.TrimSpace(note); len([]rune(note)) > 1000 {
		return nil, errs.InvalidArgument("the note is too long (1,000 characters at most)")
	}
	p, err := s.Get(ctx, id)
	if err != nil {
		return nil, err
	}
	if !s.visible(ctx, caller, p, map[string]bool{}) {
		return nil, errs.Permission("not a member of the space")
	}
	if p.AuthorID == caller {
		return nil, errs.InvalidArgument("you cannot report your own post")
	}
	now := time.Now().UTC()
	r := &post.Report{
		ReporterID: caller, PostID: p.ID, AccusedID: p.AuthorID,
		Reason: reason, Note: note, Body: p.Body, Status: reportOpen,
	}
	var existing []post.Report
	_ = s.R.List(ctx, "post_reports", database.Filter{Equal: map[string]any{
		"reporter_id": caller.String(), "post_id": p.ID.String(), "status": reportOpen,
	}, Limit: 1}, &existing)
	if len(existing) > 0 {
		r.Entity = existing[0].Entity
		r.UpdatedAt = now
		if err := s.R.Update(ctx, "post_reports", r.ID, r); err != nil {
			return nil, err
		}
		return r, nil
	}
	rid, err := identity.New(s.K.NodeID())
	if err != nil {
		return nil, err
	}
	r.Entity = entity.Entity{ID: rid, CreatedAt: now, UpdatedAt: now}
	if err := s.R.CreateID(ctx, "post_reports", rid, r); err != nil {
		return nil, err
	}
	s.L.Info("post reported", "report", rid.String(), "post", p.ID.String(), "reason", reason)
	return r, nil
}

// Reports lists the post reports with status (open, resolved, dismissed;
// "all" for every one), newest first, and how many are open.
func (s *Service) Reports(ctx context.Context, status string, limit int) ([]map[string]any, int64, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	f := database.Filter{OrderBy: "created_at", Asc: false, Limit: limit}
	switch status {
	case "all":
	case "":
		f.Equal = map[string]any{"status": reportOpen}
	case reportOpen, reportResolved, reportDismissed:
		f.Equal = map[string]any{"status": status}
	default:
		return nil, 0, errs.InvalidArgument("status must be open, resolved, dismissed or all")
	}
	var rows []post.Report
	if err := s.R.List(ctx, "post_reports", f, &rows); err != nil {
		return nil, 0, err
	}
	open, _ := s.R.Count(ctx, "post_reports", database.Filter{Equal: map[string]any{"status": reportOpen}})
	people := map[string]map[string]any{}
	person := func(id identity.ID) map[string]any {
		if v, ok := people[id.String()]; ok {
			return v
		}
		v := s.author(ctx, id)
		people[id.String()] = v
		return v
	}
	out := make([]map[string]any, 0, len(rows))
	for _, r := range rows {
		row := map[string]any{
			"id": r.ID.String(), "created_at": r.CreatedAt, "updated_at": r.UpdatedAt, "status": r.Status,
			"reason": r.Reason, "note": r.Note, "post_id": r.PostID.String(), "body": r.Body,
			"reporter": person(r.ReporterID), "accused": person(r.AccusedID), "kind": "post",
		}
		if p, err := s.Get(ctx, r.PostID); err == nil {
			row["current_body"] = p.Body
		} else {
			row["deleted"] = true
		}
		if id, err := identity.Parse(r.ResolvedBy); err == nil {
			row["resolved_by"] = person(id)
			row["resolved_at"] = r.ResolvedAt
		}
		out = append(out, row)
	}
	return out, open, nil
}

// ResolveReport resolves, dismisses or reopens ("open") a post report.
func (s *Service) ResolveReport(ctx context.Context, admin, id identity.ID, status string) error {
	if status != reportResolved && status != reportDismissed && status != reportOpen {
		return errs.InvalidArgument("status must be resolved, dismissed or open")
	}
	var r post.Report
	if err := s.R.Get(ctx, "post_reports", id, &r); err != nil {
		return err
	}
	now := time.Now().UTC()
	r.Status, r.UpdatedAt = status, now
	if status == reportOpen {
		r.ResolvedBy, r.ResolvedAt = "", time.Time{}
	} else {
		r.ResolvedBy, r.ResolvedAt = admin.String(), now
	}
	return s.R.Update(ctx, "post_reports", id, &r)
}

// RemoveReported deletes a reported post as a node admin and resolves every
// open report of it.
func (s *Service) RemoveReported(ctx context.Context, admin, postID identity.ID) error {
	if _, err := s.Get(ctx, postID); err == nil {
		if err := s.R.Delete(ctx, "posts", postID); err != nil {
			return err
		}
	}
	var open []post.Report
	if err := s.R.List(ctx, "post_reports", database.Filter{Equal: map[string]any{
		"post_id": postID.String(), "status": reportOpen,
	}}, &open); err != nil {
		return err
	}
	for _, r := range open {
		if err := s.ResolveReport(ctx, admin, r.ID, reportResolved); err != nil {
			return err
		}
	}
	return nil
}
