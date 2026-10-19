package llm

import (
	"context"
	"regexp"
	"strings"

	"github.com/tradera/tradera/plugins/actions/llm/dto"
	"github.com/tradera/tradera/plugins/actions/llm/models"
)

var nonSlug = regexp.MustCompile(`[^a-z0-9]+`)

func slugOf(text string) string {
	return strings.Trim(nonSlug.ReplaceAllString(strings.ToLower(text), "-"), "-")
}

// Offerings lists every model of every enabled provider with what the
// developer API needs to call it: the endpoint, the key and the prices. It is
// the one place that turns the admin's providers into the developer catalog,
// so a model added in Admin → Models is served there without anything else.
//
// A provider is named in a request by its kind (`vertex`); two providers of
// one kind are told apart by their names.
func (s *Service) Offerings(ctx context.Context) ([]dto.Offering, error) {
	all, err := s.List(ctx)
	if err != nil {
		return nil, err
	}
	kinds := map[string]int{}
	for i := range all {
		if all[i].Enabled && all[i].APIKey != "" {
			kinds[string(all[i].Kind)]++
		}
	}
	var out []dto.Offering
	used := map[string]bool{}
	for i := range all {
		p := &all[i]
		if !p.Enabled || p.APIKey == "" {
			continue
		}
		slug := slugOf(string(p.Kind))
		if kinds[string(p.Kind)] > 1 || p.Kind == llmprovider.KindCustom || slug == "" {
			slug = slugOf(p.Name)
		}
		for base, n := slug, 2; used[slug]; n++ {
			slug = base + "-" + string(rune('0'+n%10))
		}
		used[slug] = true
		baseURL := p.BaseURL
		if p.Kind == "vertex" || strings.Contains(baseURL, "aiplatform.googleapis.com") {
			baseURL = ResolveVertexURL(ctx, baseURL, p.APIKey)
		}
		base := dto.Offering{Provider: p.ID.String(), Slug: slug, Name: p.Name, Kind: string(p.Kind), IsDefault: p.IsDefault,
			Owner: p.OwnerID, BaseURL: baseURL, APIKey: p.APIKey}
		for _, m := range p.ParseModels() {
			m = m.WithCapabilities()
			o := base
			o.Model, o.InputPrice, o.OutputPrice, o.ContextWindow = m.ID, m.InputPrice, m.OutputPrice, ContextWindow(m)
			o.Tags, o.Inputs, o.Label = m.Tags, m.Inputs, m.Name
			if m.Unpriced || m.Disabled {
				continue // not served until it has a price, nor while it is disabled
			}
			o.Type = ""
			for _, c := range llmprovider.Capabilities {
				if m.Has(c) {
					o.Type = c
					break
				}
			}
			if o.Type == "" {
				continue
			}
			if u := m.Units; u != nil {
				o.PerImage, o.PerSecond, o.PerSecondBy, o.PerCharacter, o.PerSearch = u.Image, u.Second, u.SecondBy, u.Character, u.Search
			}
			out = append(out, o)
		}
		if p.ImageModel != "" {
			o := base
			o.Model, o.Type, o.PerImage = p.ImageModel, "image", p.ImagePrice
			out = append(out, o)
		}
	}
	return out, nil
}
