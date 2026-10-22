package posts

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/posts/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// postUpdateAction implements posts.post_update.
type postUpdateAction struct{ s *Service }

func (a *postUpdateAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "post_update", Summary: "Edit one of my posts"}
}
func (a *postUpdateAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireAuthenticated(req); err != nil {
		return nil, err
	}
	var in struct {
		Post string `json:"post"`
		Body string `json:"body"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Post)
	if err != nil {
		return nil, errs.InvalidArgument("invalid post id")
	}
	p, err := a.s.Update(ctx, req.Caller.ID, id, in.Body)
	if err != nil {
		return nil, err
	}
	views := a.s.Views(ctx, req.Caller.ID, []post.Post{*p})
	if len(views) == 0 {
		return helper.JSON(map[string]any{"ok": true})
	}
	return helper.JSON(map[string]any{"ok": true, "post": views[0]})
}

// postReportAction implements posts.post_report.
type postReportAction struct{ s *Service }

func (a *postReportAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "post_report", Summary: "Report a post to the node's admins"}
}
func (a *postReportAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Post   string `json:"post"`
		Reason string `json:"reason"`
		Note   string `json:"note,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.Post)
	if err != nil {
		return nil, errs.InvalidArgument("invalid post id")
	}
	r, err := a.s.Report(ctx, req.Caller.ID, id, in.Reason, in.Note)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "id": r.ID.String()})
}

// postAdminReportsAction implements posts.admin_post_reports.
type postAdminReportsAction struct{ s *Service }

func (a *postAdminReportsAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "admin_post_reports", Summary: "Admin: the posts people reported"}
}
func (a *postAdminReportsAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, a.s.R, req, a.s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	var in struct {
		Status string `json:"status,omitempty"` // open (default), resolved, dismissed or all
		Limit  int    `json:"limit,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	rows, open, err := a.s.Reports(ctx, in.Status, in.Limit)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"reports": rows, "open": open})
}

// postAdminReportResolveAction implements posts.admin_post_report_resolve.
type postAdminReportResolveAction struct{ s *Service }

func (a *postAdminReportResolveAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "posts", Name: "admin_post_report_resolve", Summary: "Admin: resolve, dismiss or reopen a post report, or remove the reported post"}
}
func (a *postAdminReportResolveAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireNodeAdmin(ctx, a.s.R, req, a.s.K.Env()["admin_handle"]); err != nil {
		return nil, err
	}
	var in struct {
		ID     string `json:"id"`
		Status string `json:"status"` // resolved, dismissed or open (reopen)
		// RemovePost deletes the reported post and resolves its reports.
		RemovePost bool `json:"remove_post,omitempty"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	id, err := identity.Parse(in.ID)
	if err != nil {
		return nil, errs.InvalidArgument("invalid report id")
	}
	if in.RemovePost {
		var r post.Report
		if err := a.s.R.Get(ctx, "post_reports", id, &r); err != nil {
			return nil, err
		}
		if err := a.s.RemoveReported(ctx, req.Caller.ID, r.PostID); err != nil {
			return nil, err
		}
		return helper.JSON(map[string]any{"ok": true, "status": reportResolved})
	}
	if err := a.s.ResolveReport(ctx, req.Caller.ID, id, in.Status); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "status": in.Status})
}
