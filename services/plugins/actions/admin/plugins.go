package admin

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

type pluginsBuildAction struct{ s *Service }

func (a *pluginsBuildAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "plugins_build", Summary: "Compile a versioned native plugin from the node source tree"}
}
func (a *pluginsBuildAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Source string `json:"source"`
		Output string `json:"output"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	path, err := a.s.K.BuildPlugin(ctx, in.Source, in.Output)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"path": path})
}

type pluginsStopAction struct{ s *Service }

func (a *pluginsStopAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "plugins_stop", Summary: "Drain and stop a loaded plugin"}
}
func (a *pluginsStopAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Name string `json:"name"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if a.s.asyncLifecycle(in.Name) {
		go func() {
			if err := a.s.K.Stop(in.Name); err != nil {
				a.s.L.Error("admin stop failed", "error", err)
			}
		}()
		return helper.JSON(map[string]any{"state": "stopping"})
	}
	if err := a.s.K.Stop(in.Name); err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"state": "stopped"})
}

type pluginsReplaceAction struct{ s *Service }

func (a *pluginsReplaceAction) Meta() api.ActionMeta {
	return api.ActionMeta{Namespace: "admin", Name: "plugins_replace", Summary: "Replace a plugin using a versioned compatible native binary"}
}
func (a *pluginsReplaceAction) Handle(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	var in struct {
		Name   string         `json:"name"`
		Path   string         `json:"path"`
		Config map[string]any `json:"config"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if a.s.asyncLifecycle(in.Name) {
		go func() {
			if _, err := a.s.K.ReplacePlugin(context.Background(), in.Name, in.Path, in.Config); err != nil {
				a.s.L.Error("admin replacement failed", "error", err)
			}
		}()
		return helper.JSON(map[string]any{"state": "replacing"})
	}
	info, err := a.s.K.ReplacePlugin(ctx, in.Name, in.Path, in.Config)
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"plugin": info.Name, "state": "started"})
}

func (s *Service) asyncLifecycle(name string) bool {
	if name == "admin-ns" {
		return true
	}
	entry, ok := s.K.Registry().Get(name)
	return ok && entry.Plugin.Info().Category == api.CategoryNetwork && s.K.Active(api.CategoryNetwork) == name
}
