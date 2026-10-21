package market

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/module"
	models "github.com/aseman/aseman/plugins/actions/market/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/actions/support/schema"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "market-ns", Version: "1.0.0", Provides: []string{"service/market"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		r := repo.New(d.Kernel)
		log := d.Logger
		s := NewService(d.Kernel, r, botLoaderBridge{K: d.Kernel}, spaceInstallerBridge{K: d.Kernel}, log)
		return module.Instance{Service: s, Actions: BuildActions(s), Bootstrap: s.Bootstrap, Models: append(schema.Models(), models.Models()...)}, nil
	})
}
