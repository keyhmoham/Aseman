package admin

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/logs"
	"github.com/aseman/aseman/internal/plugins/module"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/schema"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "admin-ns", Version: "1.0.0", Provides: []string{"service/admin"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		log := d.Logger
		runtime, ok := d.Kernel.(api.Runtime)
		if !ok {
			return module.Instance{}, errs.New(errs.CodePlugin, "host lacks plugin runtime")
		}
		sink, err := d.Kernel.Resolve("logs")
		if err != nil {
			return module.Instance{}, err
		}
		ring, ok := sink.(*logs.Ring)
		if !ok {
			return module.Instance{}, errs.New(errs.CodePlugin, "invalid logging sink")
		}
		s := NewService(runtime, ring, log)
		return module.Instance{Models: schema.Models(), Service: s, Actions: BuildActions(s)}, nil
	})
}
