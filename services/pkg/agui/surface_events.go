package agui

import "fmt"

// Aseman surface CUSTOM event names.
const (
	SurfaceCreate    = "aseman.surface.create"
	SurfaceUpdate    = "aseman.surface.update"
	SurfacePatchData = "aseman.surface.patchData"
	SurfaceDelete    = "aseman.surface.delete"

	// CatalogID is the Aseman Surface Spec catalog URI.
	CatalogID = "https://aseman.app/agui/catalogs/aseman/v1"

	// StateKey is the AG-UI state key for surface registry snapshots.
	StateKey = "aseman.surfaces"
)

// SurfaceState is one generative surface under the Aseman Surface Spec.
type SurfaceState struct {
	SurfaceID  string           `json:"surfaceId"`
	Catalog    string           `json:"catalog,omitempty"`
	Theme      map[string]any   `json:"theme,omitempty"`
	Layout     string           `json:"layout,omitempty"`
	Components []map[string]any `json:"components,omitempty"`
	Data       map[string]any   `json:"data,omitempty"`
}

// SurfaceEvents emits CUSTOM events to create a surface, set its components,
// and fill its data model. Theme may include layout (app|chat).
func SurfaceEvents(surfaceID string, components []map[string]any, data map[string]any, theme map[string]any) []Event {
	catalog := CatalogID
	layout := ""
	if theme != nil {
		if c, ok := theme["catalog"].(string); ok && c != "" {
			catalog = c
		}
		if l, ok := theme["layout"].(string); ok {
			layout = l
		}
	}
	createVal := map[string]any{
		"surfaceId": surfaceID,
		"catalog":   catalog,
		"theme":     theme,
	}
	if layout != "" {
		createVal["layout"] = layout
	}
	out := []Event{
		NewCustom(SurfaceCreate, createVal),
		NewCustom(SurfaceUpdate, map[string]any{
			"surfaceId":  surfaceID,
			"components": components,
		}),
	}
	if data != nil {
		out = append(out, NewCustom(SurfacePatchData, map[string]any{
			"surfaceId": surfaceID,
			"path":      "/",
			"value":     data,
		}))
	}
	// Also publish a state snapshot key so consumers can hydrate without CUSTOM.
	snap := map[string]any{
		StateKey: map[string]any{
			surfaceID: SurfaceState{
				SurfaceID:  surfaceID,
				Catalog:    catalog,
				Theme:      theme,
				Layout:     layout,
				Components: components,
				Data:       data,
			},
		},
	}
	out = append(out, NewStateSnapshot(snap))
	return out
}

// ApplyCustom mutates the surface registry from one CUSTOM surface event.
func (s *SurfaceState) ApplyCustom(ev Event) error {
	if ev.Type != EventCustom {
		return fmt.Errorf("not a CUSTOM event: %s", ev.Type)
	}
	val, _ := ev.Value.(map[string]any)
	if val == nil {
		return fmt.Errorf("custom value must be an object")
	}
	switch ev.Name {
	case SurfaceCreate:
		if id, _ := val["surfaceId"].(string); id != "" {
			s.SurfaceID = id
		}
		if c, _ := val["catalog"].(string); c != "" {
			s.Catalog = c
		}
		if t, ok := val["theme"].(map[string]any); ok {
			s.Theme = t
		}
		if l, _ := val["layout"].(string); l != "" {
			s.Layout = l
		}
	case SurfaceUpdate:
		if id, _ := val["surfaceId"].(string); id != "" {
			s.SurfaceID = id
		}
		if comps, ok := val["components"].([]map[string]any); ok {
			s.Components = comps
		} else if raw, ok := val["components"].([]any); ok {
			s.Components = mapsFromAny(raw)
		}
	case SurfacePatchData:
		if id, _ := val["surfaceId"].(string); id != "" {
			s.SurfaceID = id
		}
		path, _ := val["path"].(string)
		if s.Data == nil {
			s.Data = map[string]any{}
		}
		if path == "" || path == "/" {
			if m, ok := val["value"].(map[string]any); ok {
				s.Data = m
			} else {
				s.Data["."] = val["value"]
			}
			return nil
		}
		setPath(s.Data, path, val["value"])
	case SurfaceDelete:
		*s = SurfaceState{}
	default:
		return fmt.Errorf("unknown surface custom event %q", ev.Name)
	}
	return nil
}

// ApplyCustomRegistry applies a CUSTOM event to a surface-id → state map.
func ApplyCustomRegistry(reg map[string]*SurfaceState, ev Event) error {
	if ev.Type != EventCustom {
		return fmt.Errorf("not a CUSTOM event: %s", ev.Type)
	}
	val, _ := ev.Value.(map[string]any)
	if val == nil {
		return fmt.Errorf("custom value must be an object")
	}
	id, _ := val["surfaceId"].(string)
	if ev.Name == SurfaceDelete {
		if id == "" {
			return fmt.Errorf("surface delete needs surfaceId")
		}
		delete(reg, id)
		return nil
	}
	if id == "" {
		return fmt.Errorf("surface event needs surfaceId")
	}
	st := reg[id]
	if st == nil {
		st = &SurfaceState{SurfaceID: id}
		reg[id] = st
	}
	return st.ApplyCustom(ev)
}

func mapsFromAny(raw []any) []map[string]any {
	out := make([]map[string]any, 0, len(raw))
	for _, v := range raw {
		if m, ok := v.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

func setPath(root map[string]any, path string, value any) {
	for len(path) > 0 && path[0] == '/' {
		path = path[1:]
	}
	if path == "" {
		for k := range root {
			delete(root, k)
		}
		if m, ok := value.(map[string]any); ok {
			for k, v := range m {
				root[k] = v
			}
		}
		return
	}
	segs := splitPath(path)
	cur := root
	for i, seg := range segs {
		if i == len(segs)-1 {
			cur[seg] = value
			return
		}
		next, ok := cur[seg].(map[string]any)
		if !ok {
			next = map[string]any{}
			cur[seg] = next
		}
		cur = next
	}
}

func splitPath(path string) []string {
	var segs []string
	start := 0
	for i := 0; i <= len(path); i++ {
		if i == len(path) || path[i] == '/' {
			if i > start {
				segs = append(segs, path[start:i])
			}
			start = i + 1
		}
	}
	return segs
}
