package llm

import (
	"context"
	"os"
	"strings"

	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Bootstrap seeds the first LLM provider from the environment
// (ASEMAN_LLM_API_KEY, optional ASEMAN_LLM_BASE_URL, ASEMAN_LLM_MODEL
// and ASEMAN_IMAGE_MODEL) when the registry is empty. Providers are managed
// in the admin panel afterwards.
func (s *Service) Bootstrap(ctx context.Context) error {
	return s.SeedStatic(ctx, vmm.ProviderConfig{
		Kind:       "openai",
		BaseURL:    envOr("ASEMAN_LLM_BASE_URL", "https://api.openai.com/v1"),
		APIKey:     strings.TrimSpace(os.Getenv("ASEMAN_LLM_API_KEY")),
		Model:      strings.TrimSpace(os.Getenv("ASEMAN_LLM_MODEL")),
		ImageModel: strings.TrimSpace(os.Getenv("ASEMAN_IMAGE_MODEL")),
	})
}

func envOr(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return strings.TrimRight(v, "/")
	}
	return def
}
