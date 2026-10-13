package kernel

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/lifetime"
	"github.com/tradera/tradera/pkg/errs"
)

func (k *Kernel) gate(name string) *lifetime.Gate {
	value, _ := k.adapterGates.LoadOrStore(name, &lifetime.Gate{})
	return value.(*lifetime.Gate)
}
func (k *Kernel) drainAdapter(ctx context.Context, name string) error {
	e, ok := k.reg.Get(name)
	if !ok {
		return errs.NotFound("plugin " + name)
	}
	if e.Plugin.Info().Type != api.TypeAdapter {
		return nil
	}
	return k.gate(name).Drain(ctx)
}
