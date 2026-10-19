package users

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/module"
	"github.com/tradera/tradera/plugins/actions/support/metasvc"
	"github.com/tradera/tradera/plugins/actions/support/repo"
	"github.com/tradera/tradera/plugins/actions/users/schema"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "users-ns", Version: "1.0.0", Provides: []string{"service/users"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		r := repo.New(d.Kernel)
		log := d.Logger
		s := &Service{K: d.Kernel, R: r, L: log, M: &metasvc.Service{K: d.Kernel, R: r}}
		return module.Instance{Models: schema.Models(), Service: s, Mount: s.encryptLegacyDirects, Actions: BuildActions(s)}, nil
	})
}
