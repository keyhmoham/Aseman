package finance

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/module"
	"github.com/tradera/tradera/plugins/actions/finance/schema"
	"github.com/tradera/tradera/plugins/actions/support/repo"
)

func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "finance-ns", Version: "1.0.0", Provides: []string{"service/finance"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		s := &Service{K: d.Kernel, R: repo.New(d.Kernel), L: d.Logger}
		return module.Instance{Service: s, Actions: BuildActions(s), Models: schema.Models(), Run: s.RunGrantExpiry}, nil
	})
}
