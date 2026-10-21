package llmprovider

import (
	"time"

	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Memory is the node's memory models setting, chosen by the admin: the models
// the agents' memory server (OpenViking) works with. The chat model reads
// finished conversations and writes down what is worth remembering; the
// embedding model turns memories into vectors so they are found by meaning.
// Unset, agents still keep and read their notes, but nothing is recalled by
// meaning or learned from their conversations.
type Memory struct {
	ID                  string    `db:"id" json:"-"`
	ChatProviderID      string    `db:"chat_provider_id" json:"chat_provider_id"`
	ChatModelID         string    `db:"chat_model_id" json:"chat_model_id"`
	EmbeddingProviderID string    `db:"embedding_provider_id" json:"embedding_provider_id"`
	EmbeddingModelID    string    `db:"embedding_model_id" json:"embedding_model_id"`
	UpdatedAt           time.Time `db:"updated_at" json:"updated_at"`
}

func llmMemory() database.Model {
	return database.Model{
		Name:  "llm_memory",
		Table: "llm_memory",
		Fields: []database.Field{
			f("id", database.KindString),
			f("chat_provider_id", database.KindString), f("chat_model_id", database.KindString),
			f("embedding_provider_id", database.KindString), f("embedding_model_id", database.KindString),
			f("updated_at", database.KindTime),
		},
	}
}
