package llm

import (
	"context"

	"github.com/tradera/tradera/plugins/actions/auth/models/account"
	models "github.com/tradera/tradera/plugins/actions/llm/models"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// SeedStatic makes the legacy endpoint available through the provider registry
// after host bootstrap has created the administrator account.
func (s *Service) SeedStatic(ctx context.Context, endpoint vmm.ProviderConfig) error {
	if endpoint.APIKey == "" {
		return nil
	}
	var accounts []account.Account
	handle := s.K.Env()["admin_handle"]
	if handle == "" {
		return nil
	}
	if err := s.R.List(ctx, "accounts", database.Filter{Equal: map[string]any{"handle": handle}}, &accounts); err != nil {
		return err
	}
	if len(accounts) == 0 {
		return nil
	}
	if endpoint.Model == "" {
		endpoint.Model = "gpt-5.4"
	}
	if endpoint.ImageModel == "" {
		endpoint.ImageModel = "gpt-image-1"
	}
	_, err := s.SeedIfEmpty(ctx, accounts[0].ID, ProviderInput{Name: "OpenAI", Kind: models.KindOpenAI, BaseURL: endpoint.BaseURL, APIKey: endpoint.APIKey, Models: []models.Model{{ID: endpoint.Model, InputPrice: 1000, OutputPrice: 2000}}, ImageModel: endpoint.ImageModel, ImagePrice: 20})
	return err
}
