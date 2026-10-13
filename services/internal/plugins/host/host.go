// Package host bridges in-process builtin plugins and external Go plugins
// compiled with -buildmode=plugin. External plugin binaries must export a
// symbol `New` of type api.Factory (see Export).
package host

import (
	"fmt"
	"plugin"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
)

// Loader materializes external plugins from compiled .so files.
type Loader struct {
	log *logger.Logger
}

// NewLoader creates a loader.
func NewLoader(log *logger.Logger) *Loader {
	return &Loader{log: log.Named("plugin-host")}
}

// Load opens a Go plugin file and calls its exported New factory.
func (l *Loader) Load(path string) (loaded api.Plugin, loadErr error) {
	defer func() {
		if fault := recover(); fault != nil {
			loaded = nil
			loadErr = errs.New(errs.CodePlugin, fmt.Sprintf("plugin factory %s panicked: %v", path, fault))
		}
	}()
	p, err := plugin.Open(path)
	if err != nil {
		return nil, errs.Wrap(errs.CodePlugin, err, "open plugin "+path)
	}
	sym, err := p.Lookup("New")
	if err != nil {
		return nil, errs.Wrap(errs.CodePlugin, err, "plugin "+path+" missing New symbol")
	}
	var factory func() (api.Plugin, error)
	switch exported := sym.(type) {
	case func() (api.Plugin, error):
		factory = exported
	case api.Factory:
		factory = exported
	case *func() (api.Plugin, error):
		factory = *exported
	case *api.Factory:
		factory = *exported
	default:
		return nil, errs.New(errs.CodePlugin, fmt.Sprintf("plugin %s has an incompatible New factory", path))
	}
	instance, err := factory()
	if err != nil {
		return nil, err
	}
	if instance == nil {
		return nil, errs.New(errs.CodePlugin, "plugin factory returned nil")
	}
	return instance, nil
}

// Export is called by external plugin source to declare the factory function
// used by the host. It only validates the signature; actual registration is
// performed by the host loader.
func Export(factory func() (api.Plugin, error)) {
	_ = factory
}
