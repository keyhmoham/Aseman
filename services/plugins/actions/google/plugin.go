package google

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/module"
	gm "github.com/aseman/aseman/plugins/actions/google/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "google-ns", Version: "1.0.0", Provides: []string{"service/google"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		s := NewService(d.Kernel, repo.New(d.Kernel), d.Logger)
		var release func()
		return module.Instance{Service: s, Models: gm.Models(), Actions: s.actions(),
			Mount: func(context.Context) error {
				binder, ok := d.Kernel.(api.NetworkBindings)
				if !ok {
					return nil
				}
				var err error
				release, err = binder.BindRoutes("google", func(n network.Network) error {
					if err := n.Handle(network.MethodGet, CallbackPath, s.serveCallback); err != nil {
						return err
					}
					return n.Handle(network.MethodPost, MCPPath, s.serveMCP)
				}, func(n network.Network) error {
					_ = n.Unhandle(network.MethodPost, MCPPath)
					return n.Unhandle(network.MethodGet, CallbackPath)
				})
				return err
			},
			// A node that had Google on before it was an app lists it once the
			// node answers its own calls.
			Run: s.keepAppListed,
			Close: func(context.Context) error {
				if release != nil {
					release()
				}
				return nil
			}}, nil
	})
}
