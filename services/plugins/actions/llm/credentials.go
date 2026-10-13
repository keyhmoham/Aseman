package llm

import (
	"context"
	"strings"

	"github.com/tradera/tradera/pkg/crypto"
	"github.com/tradera/tradera/pkg/errs"
	models "github.com/tradera/tradera/plugins/actions/llm/models"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
)

func keyContext(p *models.Provider) string { return "llm_providers/" + p.ID.String() + "/api_key" }

func (s *Service) openProviderKey(p *models.Provider) error {
	if !strings.HasPrefix(p.APIKey, "tradera:secret:") {
		return nil
	} // Legacy key, migrated at bootstrap.
	key, err := crypto.OpenSecret(p.APIKey, s.K.Env()["node_private_key"], keyContext(p))
	if err != nil {
		return errs.New(errs.CodeUnavailable, "provider credential could not be decrypted")
	}
	p.APIKey = key
	return nil
}

func (s *Service) saveProvider(ctx context.Context, p *models.Provider, create bool) error {
	stored := *p // Callers and runtime clients retain the plaintext only in memory.
	if stored.APIKey != "" {
		key, err := crypto.SealSecret(stored.APIKey, s.K.Env()["node_private_key"], keyContext(p))
		if err != nil {
			return errs.New(errs.CodeUnavailable, "provider credential encryption is unavailable")
		}
		stored.APIKey = key
	}
	if create {
		return s.R.CreateID(ctx, model, stored.ID, &stored)
	}
	return s.R.Update(ctx, model, stored.ID, &stored)
}

// Conditional replacement preserves concurrent admin edits during migration.
func (s *Service) encryptLegacyKeys(ctx context.Context) error {
	var rows []models.Provider
	if err := s.R.List(ctx, model, database.Filter{}, &rows); err != nil {
		return err
	}
	for _, p := range rows {
		if p.APIKey == "" {
			continue
		}
		if strings.HasPrefix(p.APIKey, "tradera:secret:") {
			if err := s.openProviderKey(&p); err != nil {
				return err
			}
			continue
		}
		old := p.APIKey
		sealed, err := crypto.SealSecret(old, s.K.Env()["node_private_key"], keyContext(&p))
		if err != nil {
			return errs.New(errs.CodeUnavailable, "provider credential encryption is unavailable")
		}
		p.APIKey = sealed
		changed, err := s.R.CompareAndSwap(ctx, model, p.ID.String(), map[string]any{"api_key": old, "updated_at": p.UpdatedAt}, &p)
		if err != nil {
			return err
		}
		if !changed {
			return errs.Conflict("provider changed during credential migration; retry bootstrap")
		}
	}
	return nil
}
