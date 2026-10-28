package channels

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/module"
	cm "github.com/aseman/aseman/plugins/actions/channels/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "channels-ns", Version: "1.0.0", Provides: []string{"service/channels"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		s := NewService(d.Kernel, repo.New(d.Kernel), d.Logger)
		s.Spaces, s.Governance = spacesBridge{K: d.Kernel}, governanceBridge{K: d.Kernel}
		routes := []struct {
			path string
			h    network.Handler
		}{{SlackEventsPath, s.serveSlackEvents}, {SlackActionsPath, s.serveSlackActions}, {TeamsMessagesPath, s.serveTeams}, {TwilioSMSPath, s.serveSMS}}
		var release func()
		return module.Instance{Service: s, Models: cm.Models(), Actions: s.actions(),
			Mount: func(context.Context) error {
				binder, ok := d.Kernel.(api.NetworkBindings)
				if !ok {
					return nil
				}
				var err error
				release, err = binder.BindRoutes("channels", func(n network.Network) error {
					for _, r := range routes {
						if err := n.Handle(network.MethodPost, r.path, r.h); err != nil {
							return err
						}
					}
					return nil
				}, func(n network.Network) error {
					var first error
					for _, r := range routes {
						if err := n.Unhandle(network.MethodPost, r.path); err != nil && first == nil {
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
