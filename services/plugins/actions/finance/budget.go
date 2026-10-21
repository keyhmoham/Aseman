package finance

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/finance/models"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

func moneyNumber(v any) int64 {
	switch n := v.(type) {
	case float64:
		return int64(n)
	case int64:
		return n
	case int:
		return int64(n)
	}
	return 0
}
func (s *Service) SetBudget(ctx context.Context, actor, spaceID identity.ID, cap int64) error {
	if cap < 0 {
		return errs.InvalidArgument("budget must not be negative")
	}
	var project space.Space
	if e := s.R.Get(ctx, "spaces", spaceID, &project); e != nil {
		return e
	}
	if e := helper.CheckResourceManager(helper.WithActor(ctx, actor), s.R, spaceID, identity.ID{}, project.OwnerID, "space.edit_metadata"); e != nil {
		return e
	}
	key := s.recordID("budget/" + spaceID.String())
	return s.moneyOperation(ctx, func(ctx context.Context, tx database.Tx, _ int64) error {
		var record models.Record
		e := tx.Get(ctx, "financial_records", key, &record)
		if e != nil && errs.CodeOf(e) != errs.CodeNotFound {
			return e
		}
		if record.Data == nil {
			record = models.Record{ID: key, Owner: project.OwnerID.String(), Kind: "budget", Status: "active", Data: map[string]any{"space_id": spaceID.String(), "space_name": project.Name, "spent": int64(0)}, CreatedAt: time.Now().UTC()}
		}
		record.Amount = cap
		record.UpdatedAt = time.Now().UTC()
		if errs.CodeOf(e) == errs.CodeNotFound {
			return tx.Create(ctx, "financial_records", key, &record)
		}
		return tx.Update(ctx, "financial_records", key, &record)
	})
}
func (s *Service) budgetSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		Space string `json:"space"`
		Cap   int64  `json:"cap"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	id, e := identity.Parse(in.Space)
	if e != nil {
		return nil, e
	}
	if e = s.SetBudget(ctx, req.Caller.ID, id, in.Cap); e != nil {
		return nil, e
	}
	return helper.JSON(map[string]any{"ok": true})
}

// chargeBudget counts a charge against the project's budget (see below).
func (s *Service) chargeBudget(ctx context.Context, tx database.Tx, spaceID string, amount int64) error {
	if spaceID == "" {
		return nil
	}
	key := s.recordID("budget/" + spaceID)
	var b models.Record
	e := tx.Get(ctx, "financial_records", key, &b)
	if errs.CodeOf(e) == errs.CodeNotFound {
		// No budget set yet: the project has no limit, but what it spends is
		// still counted, so a budget set later sees the whole picture.
		var project space.Space
		if pe := tx.Get(ctx, "spaces", spaceID, &project); pe != nil {
			return nil // not a project (or deleted): nothing to count against
		}
		now := time.Now().UTC()
		return tx.Create(ctx, "financial_records", key, &models.Record{ID: key, Owner: project.OwnerID.String(), Kind: "budget", Status: "active",
			Data: map[string]any{"space_id": spaceID, "space_name": project.Name, "spent": amount}, CreatedAt: now, UpdatedAt: now})
	}
	if e != nil {
		return e
	}
	// Charges are for work that has already been done, so they are always
	// recorded — refusing one would leave the work unpaid. The budget is
	// enforced where work starts (EnsureFunds, before every run, tool call and
	// model call), so a project can end a run at most one step past its cap.
	spent := moneyNumber(b.Data["spent"])
	b.Data["spent"] = spent + amount
	b.UpdatedAt = time.Now().UTC()
	return tx.Update(ctx, "financial_records", key, &b)
}
func (s *Service) Budget(ctx context.Context, spaceID string) (map[string]any, error) {
	var b models.Record
	e := s.R.GetString(ctx, "financial_records", s.recordID("budget/"+spaceID), &b)
	if errs.CodeOf(e) == errs.CodeNotFound {
		return map[string]any{"cap": int64(0), "spent": int64(0)}, nil
	}
	if e != nil {
		return nil, e
	}
	return map[string]any{"cap": b.Amount, "spent": moneyNumber(b.Data["spent"])}, nil
}
