package governance

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/module"
	gov "github.com/aseman/aseman/plugins/actions/governance/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "governance-ns", Version: "1.0.0", Provides: []string{"service/governance"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		s := NewService(d.Kernel, repo.New(d.Kernel), d.Logger)
		s.Spaces = spacesBridge{K: d.Kernel}
		s.Users = usersBridge{K: d.Kernel}
		var release func()
		return module.Instance{Service: s, Models: gov.Models(), Actions: s.actions(),
			Mount: func(context.Context) error {
				binder, ok := d.Kernel.(api.NetworkBindings)
				if !ok {
					return nil
				}
				var err error
				release, err = binder.BindRoutes("governance", s.bindRoutes, s.unbindRoutes)
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

func (s *Service) bindRoutes(n network.Network) error {
	return n.Handle(network.MethodGet, EgressPath, s.serveEgress)
}

func (s *Service) unbindRoutes(n network.Network) error {
	return n.Unhandle(network.MethodGet, EgressPath)
}
