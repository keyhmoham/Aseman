package themes

import (
	"context"
	"encoding/json"

	"github.com/aseman/aseman/internal/plugins/identity"
)

// SamplePacks returns built-in catalogue themes mirrored from the Flutter
// DefaultThemePacks (high contrast + compact; Sky stays client-default).
func SamplePacks() []sampleTheme {
	return []sampleTheme{
		{
			Name:        "High contrast",
			Description: "Stronger borders, denser ink, reduced glass blur.",
			Pack:        mustJSON(highContrastPack()),
		},
		{
			Name:        "Compact",
			Description: "Tighter spacing, smaller radii, reordered home and store tabs.",
			Pack:        mustJSON(compactPack()),
		},
	}
}

type sampleTheme struct {
	Name, Description, Pack string
}

// ImportSamples creates and publishes the sample theme catalogue for an admin.
func (s *Service) ImportSamples(ctx context.Context, owner identity.ID) (created int, err error) {
	for _, sample := range SamplePacks() {
		_, _, _, err := s.Create(ctx, owner, sample.Name, sample.Description, sample.Pack, true)
		if err != nil {
			return created, err
		}
		created++
	}
	return created, nil
}

func mustJSON(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(b)
}

func highContrastPack() map[string]any {
	return map[string]any{
		"schema": "aseman.theme/v1",
		"meta": map[string]any{
			"id": "sample.high_contrast", "name": "High contrast",
			"description": "Stronger borders, denser ink, reduced glass blur.",
			"author":      "Aseman", "builtin": false,
			"preview_colors": []string{"ff000000", "ffffffff", "ff1565c0"},
		},
		"tokens": map[string]any{
			"light": map[string]any{
				"accent": "ff0d47a1", "secondary_accent": "ff00695c",
				"scaffold": "fff5f5f5", "surface": "ffffffff",
				"card_alpha": 0.92, "overlay_alpha": 0.96, "blur_sigma": 6,
				"radius_card": 12, "radius_inner": 10, "radius_control": 8,
				"title_weight": 900, "label_weight": 800,
			},
			"dark": map[string]any{
				"accent": "ff90caf9", "secondary_accent": "ff80cbc4",
				"scaffold": "ff000000", "surface": "ff121212",
				"card_alpha": 0.94, "overlay_alpha": 0.98, "blur_sigma": 4,
				"radius_card": 12, "radius_inner": 10, "radius_control": 8,
				"title_weight": 900, "label_weight": 800,
			},
		},
		"graphics": map[string]any{"atmosphere": "flat", "halo_style": "square", "icon_treatment": "sharp"},
		"shell":    map[string]any{},
		"palettes": []any{
			map[string]any{"id": "blue", "label": "Blue", "accent": "ff0d47a1", "secondary": "ff00695c"},
			map[string]any{"id": "ink", "label": "Ink", "accent": "ff111111", "secondary": "ff1565c0"},
			map[string]any{"id": "forest", "label": "Forest", "accent": "ff1b5e20", "secondary": "ff00695c"},
			map[string]any{"id": "amber", "label": "Amber", "accent": "ffe65100", "secondary": "ff0d47a1"},
		},
	}
}

func compactPack() map[string]any {
	return map[string]any{
		"schema": "aseman.theme/v1",
		"meta": map[string]any{
			"id": "sample.compact", "name": "Compact",
			"description": "Tighter spacing, smaller radii, reordered tabs.",
			"author":      "Aseman",
			"preview_colors": []string{"ff5c6bc0", "ff26a69a", "ffe8eaf6"},
		},
		"tokens": map[string]any{
			"light": map[string]any{
				"accent": "ff5c6bc0", "secondary_accent": "ff26a69a",
				"radius_card": 16, "radius_inner": 12, "radius_control": 10,
				"spacing_scale": 0.85, "density": -1, "nav_height": 58,
			},
			"dark": map[string]any{
				"accent": "ff9fa8da", "secondary_accent": "ff4db6ac",
				"radius_card": 16, "radius_inner": 12, "radius_control": 10,
				"spacing_scale": 0.85, "density": -1, "nav_height": 58,
			},
		},
		"graphics": map[string]any{"atmosphere": "mist"},
		"shell": map[string]any{
			"home": map[string]any{
				"phone_tabs": []string{"home.explore", "home.chats", "home.you"},
			},
			"store": map[string]any{
				"tabs": []string{"store.themes", "store.discover", "store.library"},
			},
		},
		"palettes": []any{
			map[string]any{"id": "indigo", "label": "Indigo", "accent": "ff5c6bc0", "secondary": "ff26a69a"},
			map[string]any{"id": "teal", "label": "Teal", "accent": "ff26a69a", "secondary": "ff5c6bc0"},
			map[string]any{"id": "violet", "label": "Violet", "accent": "ff7e57c2", "secondary": "ff26a69a"},
			map[string]any{"id": "coral", "label": "Coral", "accent": "ffef5350", "secondary": "ff5c6bc0"},
		},
	}
}
