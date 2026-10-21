package llm

import (
	"context"
	"math"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	llmprovider "github.com/aseman/aseman/plugins/actions/llm/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// imageTable is the database model of the image model setting.
const imageTable = "llm_image"

func (s *Service) imageID() string { return s.K.NodeID().String() + "image" }

// ImageInput is the admin form of the image model setting.
type ImageInput struct {
	Enabled    bool   `json:"enabled"`
	ProviderID string `json:"provider_id"`
	ModelID    string `json:"model_id"`
}

// ImageSetting returns the stored image model setting (off when never set).
func (s *Service) ImageSetting(ctx context.Context) (*llmprovider.ImageSetting, error) {
	var d llmprovider.ImageSetting
	err := s.R.GetString(ctx, imageTable, s.imageID(), &d)
	if errs.CodeOf(err) == errs.CodeNotFound {
		return &llmprovider.ImageSetting{ID: s.imageID()}, nil
	}
	if err != nil {
		return nil, err
	}
	return &d, nil
}

// SetImageSetting stores the image model setting. Turning it on needs an
// enabled provider with an API key and one of its image models.
func (s *Service) SetImageSetting(ctx context.Context, in ImageInput) (*llmprovider.ImageSetting, error) {
	in.ProviderID = strings.TrimSpace(in.ProviderID)
	in.ModelID = strings.TrimSpace(in.ModelID)
	if in.Enabled || in.ProviderID != "" {
		if in.ProviderID == "" || in.ModelID == "" {
			return nil, errs.InvalidArgument("pick a provider and one of its image models")
		}
		if _, _, err := s.imageModel(ctx, in.ProviderID, in.ModelID); err != nil {
			return nil, err
		}
	}
	d, err := s.ImageSetting(ctx)
	if err != nil {
		return nil, err
	}
	creating := d.UpdatedAt.IsZero()
	d.Enabled, d.ProviderID, d.ModelID, d.UpdatedAt = in.Enabled, in.ProviderID, in.ModelID, time.Now().UTC()
	if creating {
		err = s.R.DB.Create(ctx, imageTable, d.ID, d)
	} else {
		err = s.R.DB.Update(ctx, imageTable, d.ID, d)
	}
	if err != nil {
		return nil, err
	}
	return d, nil
}

// imageModel resolves a provider (by id) and one of its image models.
func (s *Service) imageModel(ctx context.Context, providerID, modelID string) (*llmprovider.Provider, llmprovider.Model, error) {
	all, err := s.List(ctx)
	if err != nil {
		return nil, llmprovider.Model{}, err
	}
	for i := range all {
		p := &all[i]
		if p.ID.String() != providerID {
			continue
		}
		if !p.Enabled || p.APIKey == "" {
			return nil, llmprovider.Model{}, errs.New(errs.CodeUnavailable, "LLM provider "+p.Name+" is disabled or has no API key")
		}
		m, ok := p.Model(modelID)
		if !ok {
			return nil, llmprovider.Model{}, errs.InvalidArgument("model " + modelID + " is not offered by " + p.Name)
		}
		if !m.Has(llmprovider.CapabilityImage) {
			return nil, llmprovider.Model{}, errs.InvalidArgument("model " + modelID + " is not an image model (mark it as one on the Models page)")
		}
		return p, m, nil
	}
	return nil, llmprovider.Model{}, errs.NotFound("LLM provider " + providerID)
}

// imagePriced reports whether a model has any price the node can charge an
// image by: per image, per token, or both.
func imagePriced(m llmprovider.Model) bool {
	return m.InputPrice > 0 || m.OutputPrice > 0 || (m.Units != nil && m.Units.Image > 0)
}

// imageCost prices one generation in ledger units, rounded up: the model's
// price per image times the images, plus its token prices times the tokens the
// provider reported. A model priced only per image ignores the tokens and one
// priced only by tokens ignores the count, so both kinds of pricing (and a mix)
// work for any provider.
func imageCost(m llmprovider.Model, images, tokensIn, tokensOut int64) float64 {
	var perImage float64
	if m.Units != nil {
		perImage = m.Units.Image
	}
	c := float64(images)*perImage + (float64(tokensIn)*m.InputPrice+float64(tokensOut)*m.OutputPrice)/1e6
	if c <= 0 {
		return 0
	}
	return math.Ceil(c - 1e-9)
}

// imageView renders the setting for the admin panel: what is stored, whether
// it is in effect (and why not) and the image models to pick from.
func (s *Service) imageView(ctx context.Context) (map[string]any, error) {
	d, err := s.ImageSetting(ctx)
	if err != nil {
		return nil, err
	}
	all, err := s.List(ctx)
	if err != nil {
		return nil, err
	}
	providers := []map[string]any{}
	for i := range all {
		p := &all[i]
		if !p.Enabled || p.APIKey == "" {
			continue
		}
		image := []llmprovider.Model{}
		for _, m := range modelsView(p) {
			if m.Has(llmprovider.CapabilityImage) && !m.Disabled {
				image = append(image, m)
			}
		}
		providers = append(providers, map[string]any{"id": p.ID.String(), "name": p.Name, "kind": p.Kind, "image_models": image})
	}
	active, reason := false, "Off: agents cannot generate images."
	if d.Enabled {
		if _, m, err := s.imageModel(ctx, d.ProviderID, d.ModelID); err != nil {
			reason = "On, but unusable (" + err.Error() + "): agents cannot generate images until it is fixed."
		} else if !imagePriced(m) {
			active, reason = true, "On: agents generate images with "+d.ModelID+". It has no price on the Models page, so images are not charged."
		} else {
			active, reason = true, "On: agents generate images with "+d.ModelID+", charged at its prices on the Models page."
		}
	}
	return map[string]any{"enabled": d.Enabled, "provider_id": d.ProviderID, "model_id": d.ModelID,
		"active": active, "status": reason, "providers": providers}, nil
}

// ImageActions are the admin actions of the image model setting.
func ImageActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "llm", Name: "llm_image_get", Summary: "Read the node's image model setting",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := s.requireAdmin(req); err != nil {
					return nil, err
				}
				view, err := s.imageView(ctx)
				if err != nil {
					return nil, err
				}
				return helper.JSON(view)
			}},
		helper.Action{Namespace: "llm", Name: "llm_image_set", Summary: "Pick the node's image model and turn it on or off",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := s.requireAdmin(req); err != nil {
					return nil, err
				}
				var in ImageInput
				if err := helper.Decode(req, &in); err != nil {
					return nil, err
				}
				if _, err := s.SetImageSetting(ctx, in); err != nil {
					return nil, err
				}
				view, err := s.imageView(ctx)
				if err != nil {
					return nil, err
				}
				return helper.JSON(view)
			}},
	}
}
