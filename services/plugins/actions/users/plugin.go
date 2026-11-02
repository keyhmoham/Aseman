package users

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/module"
	"github.com/aseman/aseman/plugins/actions/support/metasvc"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/actions/users/schema"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "users-ns", Version: "1.0.0", Provides: []string{"service/users"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		r := repo.New(d.Kernel)
		log := d.Logger
		s := &Service{K: d.Kernel, R: r, L: log, M: &metasvc.Service{K: d.Kernel, R: r}}
		mount := func(ctx context.Context) error {
			s.startReminders() // what people asked their Aseman to remind them of
			s.startJobs()      // work handed to their workspace, written up in their notes when it is finished
			return s.encryptLegacyDirects(ctx)
		}
		return module.Instance{Models: schema.Models(), Service: s, Mount: mount, Actions: BuildActions(s)}, nil
	})
}
