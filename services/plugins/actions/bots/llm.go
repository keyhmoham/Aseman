package bots

import (
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
)

func providerCatalogAction(s *Service) api.Action {
	return bridge.ActionAlias(s.K, "bots", "llm_models", "llm", "llm_models", "List enabled LLM providers and models")
}
