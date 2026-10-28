package responsibilities

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/module"
	rm "github.com/aseman/aseman/plugins/actions/responsibilities/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "responsibilities-ns", Version: "1.0.0", Provides: []string{"service/responsibilities"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		s := NewService(d.Kernel, repo.New(d.Kernel), d.Logger)
		s.Spaces, s.Google, s.Tasks, s.Apps = spacesBridge{K: d.Kernel}, googleBridge{K: d.Kernel}, tasksBridge{K: d.Kernel}, appsBridge{K: d.Kernel}
		var release func()
		return module.Instance{Service: s, Models: rm.Models(), Actions: s.actions(), Run: s.Run,
			Mount: func(context.Context) error {
				binder, ok := d.Kernel.(api.NetworkBindings)
				if !ok {
					return nil
				}
				var err error
				release, err = binder.BindRoutes("responsibilities", func(n network.Network) error {
					return n.Handle(network.MethodPost, HookPath+"/{id}", s.serveHook)
				}, func(n network.Network) error { return n.Unhandle(network.MethodPost, HookPath+"/{id}") })
				return err
			},
			Close: func(context.Context) error {
				if release != nil {
					release()
				}
				return nil
			}}, nil
	})
}
