package llmprovider

import "github.com/aseman/aseman/plugins/adapters/database/ports"

func f(name string, k database.Kind) database.Field { return database.Field{Name: name, Kind: k} }

// Models belongs to this namespace and is registered by its plugin lifecycle.
func Models() []database.Model {
	return []database.Model{llmProviders(), llmDecision(), llmMemory(), llmImage(), llmVoice()}
}

func llmProviders() database.Model {
	return database.Model{
		Name:  "llm_providers",
		Table: "llm_providers",
		Fields: []database.Field{
			f("id", database.KindString), f("owner_id", database.KindString),
			f("name", database.KindString), f("kind", database.KindString),
			f("base_url", database.KindString), f("api_key", database.KindString),
			f("enabled", database.KindBool), f("is_default", database.KindBool),
			f("models", database.KindString), f("image_model", database.KindString),
			f("image_price", database.KindFloat64),
			f("created_at", database.KindTime), f("updated_at", database.KindTime),
		},
	}
}
