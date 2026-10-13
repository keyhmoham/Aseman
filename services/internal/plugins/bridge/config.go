package bridge

import (
	"encoding/json"

	"github.com/tradera/tradera/internal/plugins/api"
)

func GlobalConfig(d *api.Dependencies, out any) error {
	b, err := json.Marshal(d.Global)
	if err != nil {
		return err
	}
	var global map[string]any
	if err := json.Unmarshal(b, &global); err != nil {
		return err
	}
	mergeConfig(global, d.Config)
	b, err = json.Marshal(global)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, out)
}

func mergeConfig(target, overlay map[string]any) {
	for key, value := range overlay {
		if nested, ok := value.(map[string]any); ok {
			if current, ok := target[key].(map[string]any); ok {
				mergeConfig(current, nested)
				continue
			}
		}
		target[key] = value
	}
}
