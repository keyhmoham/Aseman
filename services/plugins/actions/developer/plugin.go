package developer

import (
	"context"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/module"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/actions/support/repo"
)

// NewPlugin constructs the namespace using only the host bridge.
func NewPlugin() api.Plugin {
	return module.New(api.Info{Name: "developer-ns", Version: "1.0.0", Provides: []string{"service/developer"}}, func(ctx context.Context, d *api.Dependencies) (module.Instance, error) {
		s := NewService(d.Kernel, repo.New(d.Kernel), d.Logger)
		s.Fin = financeBridge{K: d.Kernel}
		s.Providers = providersBridge{K: d.Kernel}
		s.Infra = infraBridge{K: d.Kernel}
		var cfg struct {
			Sandbox struct {
				Backend string `json:"backend"`
				Image   string `json:"image"`
			}
		}
		if err := bridge.GlobalConfig(d, &cfg); err != nil {
			return module.Instance{}, err
		}
		s.SandboxBackend, s.SandboxImage = cfg.Sandbox.Backend, cfg.Sandbox.Image
		var release func()
		return module.Instance{
			Service: s,
			Actions: BuildActions(s),
			Models:  models.Models(),
			Mount: func(context.Context) error {
				binder, ok := d.Kernel.(api.NetworkBindings)
				if !ok {
					return errs.New(errs.CodeUnavailable, "host does not support plugin network bindings")
				}
				var err error
				release, err = binder.BindRoutes("developer", s.Register, s.Unregister)
				return err
			},
			Run: func(ctx context.Context) {
				prune := time.NewTicker(6 * time.Hour)
				meter := time.NewTicker(20 * time.Second)
				storage := time.NewTicker(StorageEvery)
				defer storage.Stop()
				defer prune.Stop()
				defer meter.Stop()
				s.Prune(ctx)
				for {
					select {
					case <-ctx.Done():
						return
					case <-prune.C:
						s.Prune(ctx)
					case <-meter.C:
						s.MeterComputers(ctx)
					case <-storage.C:
						s.MeterStorage(ctx)
					}
				}
			},
			Close: func(context.Context) error {
				if release != nil {
					release()
				}
				return nil
			},
		}, nil
	})
}
