package llm

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/module"
	models "github.com/tradera/tradera/plugins/actions/llm/models"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/actions/support/schema"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "llm-ns", Version: "1.0.0", Provides: []string{"service/llm"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		r := repo.New(d.Kernel)
		log := d.Logger
		s := NewService(d.Kernel, r, log)
		return module.Instance{Service: s, Mount: s.encryptLegacyKeys, Actions: append(append(append(CatalogActions(s), AdminActions(s)...), DecisionActions(s)...), MemoryActions(s)...), Bootstrap: s.Bootstrap, Models: append(schema.Models(), models.Models()...)}, nil
	})
}
