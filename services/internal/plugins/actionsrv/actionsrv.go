// Package actionsrv retains the action-bundle constructor for plugin authors.
// It delegates lifecycle, cancellation and draining to the shared module SDK.
package actionsrv

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/module"
	"github.com/aseman/aseman/pkg/logger"
)

type Plugin = module.Plugin

func New(name, description, version string, actions []api.Action, log *logger.Logger) *Plugin {
	provides := make([]string, 0, len(actions))
	for _, action := range actions {
		meta := action.Meta()
		provides = append(provides, meta.Namespace+"/"+meta.Name)
	}
	return module.New(api.Info{Name: name, Description: description, Version: version, Provides: provides}, func(context.Context, *api.Dependencies) (module.Instance, error) {
		return module.Instance{Actions: actions}, nil
	})
}
