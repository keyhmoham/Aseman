package admin

import (
	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/bridge"
)

// Provider management keeps its existing admin API while implementation and
// models belong entirely to the dynamically resolved llm namespace.
func providerActions(s *Service) []api.Action {
	actions := []api.Action{}
	for _, name := range []string{"llm_providers_list", "llm_provider_set", "llm_provider_delete", "llm_kinds"} {
		actions = append(actions, bridge.ActionAlias(s.K, "admin", name, "llm", name, "Manage LLM providers"))
	}
	return actions
}
