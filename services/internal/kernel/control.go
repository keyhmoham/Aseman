package kernel

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/support/repo"
)

// Control is the fixed host maintenance surface, independent of business
// namespaces. It remains available to authenticated administrators when auth
// or admin action plugins are stopped, so they can be loaded again.
func (k *Kernel) Control(ctx context.Context, name string, req *api.ActionRequest) (*api.ActionResponse, error) {
	db := k.DB()
	if db == nil {
		if err := helper.RequireUser(req); err != nil {
			return nil, err
		}
		if !k.maintenanceAdmin(req.Caller.ID) {
			return nil, errs.Permission("verified maintenance session required while the database is disconnected")
		}
	} else {
		if err := helper.RequireNodeAdmin(ctx, &repo.Repo{DB: db}, req, k.Env()["admin_handle"]); err != nil {
			return nil, err
		}
	}

	var in struct {
		Name     string         `json:"name"`
		Path     string         `json:"path"`
		Source   string         `json:"source"`
		Output   string         `json:"output"`
		Category api.Category   `json:"category"`
		Plugin   string         `json:"plugin"`
		Config   map[string]any `json:"config"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	if entry, ok := k.reg.Get(in.Name); ok && entry.Plugin.Info().Category == api.CategoryNetwork && k.Active(api.CategoryNetwork) == in.Name {
		var operation func() error
		switch name {
		case "plugins_stop":
			operation = func() error { return k.Stop(in.Name) }
		case "plugins_unload":
			operation = func() error { return k.Unload(in.Name) }
		case "plugins_update":
			operation = func() error { return k.Update(in.Name, in.Config) }
		case "plugins_replace":
			operation = func() error { _, err := k.ReplacePlugin(context.Background(), in.Name, in.Path, in.Config); return err }
		}
		if operation != nil {
			go func() {
				if err := operation(); err != nil {
					k.log.Error("network maintenance failed", "operation", name, "plugin", in.Name, "error", err)
				}
			}()
			return helper.JSON(map[string]any{"accepted": true, "plugin": in.Name})
		}
	}
	switch name {
	case "plugins_list":
		plugins := []map[string]any{}
		for _, entry := range k.reg.List() {
			info := entry.Plugin.Info()
			plugins = append(plugins, map[string]any{"name": info.Name, "type": info.Type, "category": info.Category, "version": info.Version, "state": entry.State.String(), "last_error": entry.LastError})
		}
		return helper.JSON(map[string]any{"plugins": plugins})
	case "plugins_build":
		path, err := k.BuildPlugin(ctx, in.Source, in.Output)
		if err != nil {
			return nil, err
		}
		return helper.JSON(map[string]any{"path": path})
	case "plugins_load":
		if in.Path != "" {
			info, err := k.LoadPlugin(ctx, in.Path, in.Config)
			if err != nil {
				return nil, err
			}
			return helper.JSON(info)
		}
		if err := k.Init(in.Name); err != nil {
			return nil, err
		}
		if err := k.Start(in.Name); err != nil {
			return nil, err
		}
	case "plugins_stop":
		if err := k.Stop(in.Name); err != nil {
			return nil, err
		}
	case "plugins_unload":
		if err := k.Unload(in.Name); err != nil {
			return nil, err
		}
	case "plugins_replace":
		info, err := k.ReplacePlugin(ctx, in.Name, in.Path, in.Config)
		if err != nil {
			return nil, err
		}
		return helper.JSON(info)
	case "plugins_update":
		if err := k.Update(in.Name, in.Config); err != nil {
			return nil, err
		}
	case "plugins_set_active":
		if err := k.SetActive(in.Category, in.Plugin); err != nil {
			return nil, err
		}
	default:
		return nil, errs.NotFound("host control operation " + name)
	}
	return helper.JSON(map[string]any{"ok": true, "plugin": in.Name})
}
