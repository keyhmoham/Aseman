package themes

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/module"
	themesmodel "github.com/aseman/aseman/plugins/actions/themes/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/actions/support/schema"
)

// NewPlugin constructs the themes namespace.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "themes-ns", Version: "1.0.0", Provides: []string{"service/themes"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		r := repo.New(d.Kernel)
		log := d.Logger
		s := NewService(d.Kernel, r, log)
		return module.Instance{
			Service: s,
			Actions: BuildActions(s),
			Models:  append(schema.Models(), themesmodel.Models()...),
		}, nil
	})
}
