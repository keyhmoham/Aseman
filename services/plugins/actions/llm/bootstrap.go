package llm

import (
	"context"
	"os"
	"strings"

	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

// Bootstrap seeds the first LLM provider from the environment
// (TRADERA_LLM_API_KEY, optional TRADERA_LLM_BASE_URL, TRADERA_LLM_MODEL
// and TRADERA_IMAGE_MODEL) when the registry is empty. Providers are managed
// in the admin panel afterwards.
func (s *Service) Bootstrap(ctx context.Context) error {
	return s.SeedStatic(ctx, vmm.ProviderConfig{
		Kind:       "openai",
		BaseURL:    envOr("TRADERA_LLM_BASE_URL", "https://api.openai.com/v1"),
		APIKey:     strings.TrimSpace(os.Getenv("TRADERA_LLM_API_KEY")),
		Model:      strings.TrimSpace(os.Getenv("TRADERA_LLM_MODEL")),
		ImageModel: strings.TrimSpace(os.Getenv("TRADERA_IMAGE_MODEL")),
	})
}

func envOr(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return strings.TrimRight(v, "/")
	}
	return def
}
