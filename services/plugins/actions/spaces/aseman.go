package spaces

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/spaces/models/space"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// ensureAseman adds the built-in aseman orchestrator to a space (as a bot
// member) so it can manage the space's agents/tools. Idempotent. No-op when the
// bots service isn't wired.
func (s *Service) ensureAseman(ctx context.Context, spaceID identity.ID) {
	if s.Bots == nil {
		return
	}
	rec, err := s.Bots.InstallAseman(ctx)
	if err != nil || rec == nil {
		s.L.Warn("aseman unavailable for space", "space", spaceID.String(), "error", err)
		return
	}
	// Already a member?
	if _, err := s.SpaceMembership(ctx, spaceID, rec.AccountID); err == nil {
		return
	}
	sp, err := s.GetSpace(ctx, spaceID)
	if err != nil {
		s.L.Warn("space unavailable for aseman enrollment", "space", spaceID.String(), "error", err)
		return
	}
	if err := s.AddBot(ctx, sp.OwnerID, spaceID, identity.ID{}, rec.AccountID); err != nil {
		s.L.Warn("add aseman to space", "space", spaceID.String(), "error", err)
	}
}

// EnsureAsemanEverywhere adds the aseman orchestrator to every space on
// the node (existing workspaces). Idempotent.
func (s *Service) EnsureAsemanEverywhere(ctx context.Context) error {
	var spaces []space.Space
	if err := s.R.List(ctx, "spaces", database.Filter{}, &spaces); err != nil {
		return err
	}
	added := 0
	for i := range spaces {
		// Ordinary directs stay lead-free; the person's home Aseman is both
		// Direct and Home, and needs the lead like any project.
		if spaces[i].Direct && !spaces[i].Home {
			continue
		}
		_, before := s.SpaceMembership(ctx, spaces[i].ID, s.asemanAccount(ctx))
		s.ensureAseman(ctx, spaces[i].ID)
		if before != nil {
			continue
		}
		added++
	}
	s.L.Info("aseman ensured across workspaces", "spaces", len(spaces), "added", added)
	return nil
}

func (s *Service) asemanAccount(ctx context.Context) identity.ID {
	if s.Bots == nil {
		return identity.ID{}
	}
	rec, err := s.Bots.InstallAseman(ctx)
	if err != nil || rec == nil {
		return identity.ID{}
	}
	return rec.AccountID
}

// AsemanAccount returns the built-in aseman orchestrator's account id,
// installing it if needed (idempotent).
func (s *Service) AsemanAccount(ctx context.Context) (identity.ID, error) {
	if s.Bots == nil {
		return identity.ID{}, errs.New(errs.CodeUnavailable, "bots service not wired")
	}
	rec, err := s.Bots.InstallAseman(ctx)
	if err != nil || rec == nil {
		return identity.ID{}, err
	}
	return rec.AccountID, nil
}

// asemanEnsureAction implements spaces.aseman_ensure: add aseman to
// every existing workspace (idempotent).
type asemanEnsureAction struct{ s *Service }

func (a *asemanEnsureAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "spaces", Name: "aseman_ensure", Summary: "Add the built-in aseman orchestrator to every workspace"}
}
func (a *asemanEnsureAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := a.s.EnsureAsemanEverywhere(ctx); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true})
}
