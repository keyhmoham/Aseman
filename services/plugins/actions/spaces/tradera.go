package spaces

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/spaces/models/space"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// ensureTradera adds the built-in tradera orchestrator to a space (as a bot
// member) so it can manage the space's agents/tools. Idempotent. No-op when the
// bots service isn't wired.
func (s *Service) ensureTradera(ctx context.Context, spaceID identity.ID) {
	if s.Bots == nil {
		return
	}
	rec, err := s.Bots.InstallTradera(ctx)
	if err != nil || rec == nil {
		s.L.Warn("tradera unavailable for space", "space", spaceID.String(), "error", err)
		return
	}
	// Already a member?
	if _, err := s.SpaceMembership(ctx, spaceID, rec.AccountID); err == nil {
		return
	}
	sp, err := s.GetSpace(ctx, spaceID)
	if err != nil {
		s.L.Warn("space unavailable for tradera enrollment", "space", spaceID.String(), "error", err)
		return
	}
	if err := s.AddBot(ctx, sp.OwnerID, spaceID, identity.ID{}, rec.AccountID); err != nil {
		s.L.Warn("add tradera to space", "space", spaceID.String(), "error", err)
	}
}

// EnsureTraderaEverywhere adds the tradera orchestrator to every space on
// the node (existing workspaces). Idempotent.
func (s *Service) EnsureTraderaEverywhere(ctx context.Context) error {
	var spaces []space.Space
	if err := s.R.List(ctx, "spaces", database.Filter{}, &spaces); err != nil {
		return err
	}
	added := 0
	for i := range spaces {
		if spaces[i].Direct {
			continue
		}
		_, before := s.SpaceMembership(ctx, spaces[i].ID, s.traderaAccount(ctx))
		s.ensureTradera(ctx, spaces[i].ID)
		if before != nil {
			continue
		}
		added++
	}
	s.L.Info("tradera ensured across workspaces", "spaces", len(spaces), "added", added)
	return nil
}

func (s *Service) traderaAccount(ctx context.Context) identity.ID {
	if s.Bots == nil {
		return identity.ID{}
	}
	rec, err := s.Bots.InstallTradera(ctx)
	if err != nil || rec == nil {
		return identity.ID{}
	}
	return rec.AccountID
}

// TraderaAccount returns the built-in tradera orchestrator's account id,
// installing it if needed (idempotent).
func (s *Service) TraderaAccount(ctx context.Context) (identity.ID, error) {
	if s.Bots == nil {
		return identity.ID{}, errs.New(errs.CodeUnavailable, "bots service not wired")
	}
	rec, err := s.Bots.InstallTradera(ctx)
	if err != nil || rec == nil {
		return identity.ID{}, err
	}
	return rec.AccountID, nil
}

// traderaEnsureAction implements spaces.tradera_ensure: add tradera to
// every existing workspace (idempotent).
type traderaEnsureAction struct{ s *Service }

func (a *traderaEnsureAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "tradera_ensure", Summary: "Add the built-in tradera orchestrator to every workspace"}
}
func (a *traderaEnsureAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.EnsureTraderaEverywhere(ctx); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}
