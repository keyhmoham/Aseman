package llm

import (
	"context"
	"strings"

	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// ResolveChat returns only the stable adapter-facing endpoint contract.
func (s *Service) ResolveChat(ctx context.Context, provider, model string) (vmm.ProviderConfig, error) {
	p, m, err := s.Resolve(ctx, provider, model)
	if err != nil {
		return vmm.ProviderConfig{}, err
	}
	baseURL := p.BaseURL
	if p.Kind == "vertex" || strings.Contains(baseURL, "aiplatform.googleapis.com") {
		baseURL = ResolveVertexURL(ctx, baseURL, p.APIKey)
	}
	return vmm.ProviderConfig{Kind: string(p.Kind), BaseURL: baseURL, APIKey: p.APIKey, Model: m.ID, ContextWindow: ContextWindow(m)}, nil
}
func (s *Service) ResolveImageEndpoint(ctx context.Context, provider string) (vmm.ProviderConfig, error) {
	p, err := s.ResolveImage(ctx, provider)
	if err != nil {
		return vmm.ProviderConfig{}, err
	}
	baseURL := p.BaseURL
	if p.Kind == "vertex" || strings.Contains(baseURL, "aiplatform.googleapis.com") {
		baseURL = ResolveVertexURL(ctx, baseURL, p.APIKey)
	}
	return vmm.ProviderConfig{Kind: string(p.Kind), BaseURL: baseURL, APIKey: p.APIKey, ImageModel: p.ImageModel, ImagePrice: p.ImagePrice}, nil
}
