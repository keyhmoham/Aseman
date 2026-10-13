package finance

import (
	"context"
	"fmt"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/plugins/actions/finance/models"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
)

func (s *Service) reconcileAction(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]); e != nil {
		return nil, e
	}
	var rows []models.Record
	if e := s.R.List(ctx, "financial_records", database.Filter{}, &rows); e != nil {
		return nil, e
	}
	issues := []map[string]any{}
	for _, r := range rows {
		if r.Kind == "purchase" && r.Status == "pending" {
			issues = append(issues, map[string]any{"id": r.ID, "kind": "unsettled_purchase", "account_id": r.Owner})
		}
		if r.Kind == "escrow" && r.Status == "held" && time.Since(r.CreatedAt) > 24*time.Hour {
			issues = append(issues, map[string]any{"id": r.ID, "kind": "open_reservation", "account_id": r.Owner, "detail": fmt.Sprint(r.Data["reference"])})
		}
	}
	return helper.JSON(map[string]any{"ok": len(issues) == 0, "issues": issues, "checked": len(rows)})
}
