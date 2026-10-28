package enterprise

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/module"
	em "github.com/aseman/aseman/plugins/actions/enterprise/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "enterprise-ns", Version: "1.0.0", Provides: []string{"service/enterprise"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		s := NewService(d.Kernel, repo.New(d.Kernel), d.Logger)
		s.Auth, s.Spaces, s.Revoker = authBridge{K: d.Kernel}, spacesBridge{K: d.Kernel}, revokers{K: d.Kernel}
		routes := append(s.scimRoutes(), route{network.MethodGet, SSOCallbackPath, s.serveCallback})
		var release func()
		return module.Instance{Service: s, Models: em.Models(), Actions: s.actions(),
			Mount: func(context.Context) error {
				binder, ok := d.Kernel.(api.NetworkBindings)
				if !ok {
					return nil
				}
				var err error
				release, err = binder.BindRoutes("enterprise", func(n network.Network) error {
					for _, r := range routes {
						if err := n.Handle(r.method, r.path, r.handler); err != nil {
							return err
						}
					}
					return nil
				}, func(n network.Network) error {
					var first error
					for _, r := range routes {
						if err := n.Unhandle(r.method, r.path); err != nil && first == nil {
							first = err
						}
					}
					return first
				})
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
