package auth

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/module"
	"github.com/tradera/tradera/plugins/actions/auth/schema"
	"github.com/tradera/tradera/plugins/actions/support/repo"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "auth-ns", Version: "1.0.0", Provides: []string{"service/auth"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		r := repo.New(d.Kernel)
		log := d.Logger
		s := &Service{K: d.Kernel, R: r, L: log, Spaces: spacesPortBridge{K: d.Kernel}}
		return module.Instance{Models: schema.Models(), Service: s, Actions: BuildActions(s), Bootstrap: s.Bootstrap}, nil
	})
}
