package routine

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/module"
	models "github.com/aseman/aseman/plugins/actions/routines/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/actions/support/schema"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "routines-ns", Version: "1.0.0", Provides: []string{"service/routines"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		r := repo.New(d.Kernel)
		log := d.Logger
		s := NewService(d.Kernel, r, log)
		s.Spaces = spacesPortBridge{K: d.Kernel}
		return module.Instance{Service: s, Actions: BuildActions(s), Models: append(schema.Models(), models.Models()...), Run: s.Start}, nil
	})
}
