package federation

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/module"
	"github.com/tradera/tradera/pkg/errs"
	fed "github.com/tradera/tradera/plugins/actions/federation/gateway"
	"github.com/tradera/tradera/plugins/actions/federation/schema"
	"github.com/tradera/tradera/plugins/actions/finance/models/wallet"
	"github.com/tradera/tradera/plugins/actions/support/repo"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	p := module.New(api.Info{Name: "federation-ns", Version: "1.0.0", Provides: []string{"service/federation"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		r := repo.New(d.Kernel)
		log := d.Logger
		s := &Service{K: d.Kernel, R: r, L: log}
		s.Peer = fed.New(d.Kernel, financeBridge{K: d.Kernel}, d.Logger)
		var release, releaseProxy func()
		return module.Instance{Models: schema.Models(), Service: s, Actions: BuildActions(s), Bootstrap: s.Bootstrap, Mount: func(ctx context.Context) error {
			binder, ok := d.Kernel.(api.NetworkBindings)
			if !ok {
				return errs.New(errs.CodeUnavailable, "host does not support plugin network bindings")
			}
			proxyBinder, ok := d.Kernel.(api.ProxyBindings)
			if !ok {
				return errs.New(errs.CodeUnavailable, "host does not support proxy bindings")
			}
			var err error
			releaseProxy, err = proxyBinder.BindProxy("federation", func(ctx context.Context, ref, ns, name string, caller api.Caller, body []byte) (*api.ActionResponse, error) {
				var out *api.ActionResponse
				err := bridge.Invoke(ctx, d.Kernel, "federation", "Proxy", []any{ctx, ref, ns, name, caller, body}, &out)
				return out, err
			})
			if err != nil {
				return err
			}
			release, err = binder.BindRoutes("federation", s.Peer.Register, s.Peer.Unregister)
			if err != nil {
				releaseProxy()
			}
			return err
		}, Close: func(context.Context) error {
			if release != nil {
				release()
			}
			if releaseProxy != nil {
				releaseProxy()
			}
			return nil
		}}, nil
	})
	return &namespacePlugin{Plugin: p}
}

type financeBridge struct{ K api.Kernel }

func (p financeBridge) AppendReplica(ctx context.Context, entry *wallet.LedgerEntry) error {
	return bridge.Invoke(ctx, p.K, "finance", "AppendReplica", []any{ctx, entry})
}
