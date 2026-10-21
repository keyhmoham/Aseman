package llm

import (
	"context"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/llm/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// decisionTable is the database model of the decision model setting.
const decisionTable = "llm_decision"

func (s *Service) decisionID() string { return s.K.NodeID().String() + "decision" }

// DecisionInput is the admin form of the decision model setting.
type DecisionInput struct {
	Enabled    bool   `json:"enabled"`
	ProviderID string `json:"provider_id"`
	ModelID    string `json:"model_id"`
	// AutoApprove: low-risk tool calls that need approval are approved by the
	// decision model instead of waiting on a person.
	AutoApprove bool `json:"auto_approve"`
}

// Decision returns the stored decision model setting (off when never set).
func (s *Service) Decision(ctx context.Context) (*llmprovider.Decision, error) {
	var d llmprovider.Decision
	err := s.R.GetString(ctx, decisionTable, s.decisionID(), &d)
	if errs.CodeOf(err) == errs.CodeNotFound {
		return &llmprovider.Decision{ID: s.decisionID()}, nil
	}
	if err != nil {
		return nil, err
	}
	return &d, nil
}

// SetDecision stores the decision model setting. Turning it on needs an
// enabled provider with an API key and one of its decision models.
func (s *Service) SetDecision(ctx context.Context, in DecisionInput) (*llmprovider.Decision, error) {
	in.ProviderID = strings.TrimSpace(in.ProviderID)
	in.ModelID = strings.TrimSpace(in.ModelID)
	if in.Enabled || in.ProviderID != "" {
		if in.ProviderID == "" || in.ModelID == "" {
			return nil, errs.InvalidArgument("pick a provider and one of its decision models")
		}
		if _, _, err := s.decisionModel(ctx, in.ProviderID, in.ModelID); err != nil {
			return nil, err
		}
	}
	d, err := s.Decision(ctx)
	if err != nil {
		return nil, err
	}
	creating := d.UpdatedAt.IsZero()
	d.Enabled, d.ProviderID, d.ModelID, d.AutoApprove, d.UpdatedAt = in.Enabled, in.ProviderID, in.ModelID, in.AutoApprove, time.Now().UTC()
	if creating {
		err = s.R.DB.Create(ctx, decisionTable, d.ID, d)
	} else {
		err = s.R.DB.Update(ctx, decisionTable, d.ID, d)
	}
	if err != nil {
		return nil, err
	}
	return d, nil
}

// decisionModel resolves a provider (by id) and one of its decision models.
func (s *Service) decisionModel(ctx context.Context, providerID, modelID string) (*llmprovider.Provider, llmprovider.Model, error) {
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
		if !m.Decision() {
			return nil, llmprovider.Model{}, errs.InvalidArgument("model " + modelID + " is not a decision model (mark it as one on the Models page)")
		}
		return p, m, nil
	}
	return nil, llmprovider.Model{}, errs.NotFound("LLM provider " + providerID)
}

// ResolveDecision returns the endpoint of the node's decision model. It fails
// with CodeUnavailable when the decision model is off, or when its provider or
// model is no longer usable: agents then decide with their own model.
func (s *Service) ResolveDecision(ctx context.Context) (vmm.ProviderConfig, error) {
	d, err := s.Decision(ctx)
	if err != nil {
		return vmm.ProviderConfig{}, err
	}
	if !d.Enabled {
		return vmm.ProviderConfig{}, errs.New(errs.CodeUnavailable, "the decision model is off")
	}
	p, m, err := s.decisionModel(ctx, d.ProviderID, d.ModelID)
	if err != nil {
		return vmm.ProviderConfig{}, errs.New(errs.CodeUnavailable, "the decision model is unavailable: "+err.Error())
	}
	return vmm.ProviderConfig{Kind: string(p.Kind), BaseURL: p.BaseURL, APIKey: p.APIKey, Model: m.ID,
		InputPrice: m.InputPrice, OutputPrice: m.OutputPrice, AutoApprove: d.AutoApprove}, nil
}

// decisionView renders the setting for the admin panel: what is stored,
// whether it is in effect (and why not) and the decision models to pick from.
func (s *Service) decisionView(ctx context.Context) (map[string]any, error) {
	d, err := s.Decision(ctx)
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
		decision := []llmprovider.Model{}
		for _, m := range modelsView(p) {
			if m.Decision() && !m.Disabled {
				decision = append(decision, m)
			}
		}
		providers = append(providers, map[string]any{"id": p.ID.String(), "name": p.Name, "kind": p.Kind,
			"decision_models": decision})
	}
	active, reason := false, "Off: every agent decides with its own model."
	if d.Enabled {
		if _, _, err := s.decisionModel(ctx, d.ProviderID, d.ModelID); err != nil {
			reason = "On, but unusable (" + err.Error() + "): agents decide with their own model until it is fixed."
		} else {
			active, reason = true, "On: tool selection and decisions use "+d.ModelID+" with each agent's own model."
		}
	}
	return map[string]any{"enabled": d.Enabled, "provider_id": d.ProviderID, "model_id": d.ModelID,
		"auto_approve": d.AutoApprove, "active": active, "status": reason, "providers": providers}, nil
}

// DecisionActions are the admin actions of the decision model setting.
func DecisionActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "llm", Name: "llm_decision_get", Summary: "Read the node's decision model setting",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := s.requireAdmin(req); err != nil {
					return nil, err
				}
				view, err := s.decisionView(ctx)
				if err != nil {
					return nil, err
				}
				return helper.JSON(view)
			}},
		helper.Action{Namespace: "llm", Name: "llm_decision_set", Summary: "Pick the node's decision model and turn it on or off",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := s.requireAdmin(req); err != nil {
					return nil, err
				}
				var in DecisionInput
				if err := helper.Decode(req, &in); err != nil {
					return nil, err
				}
				if _, err := s.SetDecision(ctx, in); err != nil {
					return nil, err
				}
				view, err := s.decisionView(ctx)
				if err != nil {
					return nil, err
				}
				return helper.JSON(view)
			}},
	}
}
