package llmprovider

import (
	"time"

	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

// ImageSetting is the node's image model, chosen by the admin: one image model
// of an enabled provider that the agents' image_generate tool always uses,
// whatever model each agent itself runs on. It is priced like any model on the
// Models page: per image, per token, or both.
type ImageSetting struct {
	ID         string    `db:"id" json:"-"`
	Enabled    bool      `db:"enabled" json:"enabled"`
	ProviderID string    `db:"provider_id" json:"provider_id"`
	ModelID    string    `db:"model_id" json:"model_id"`
	UpdatedAt  time.Time `db:"updated_at" json:"updated_at"`
}

func llmImage() database.Model {
	return database.Model{
		Name:  "llm_image",
		Table: "llm_image",
		Fields: []database.Field{
			f("id", database.KindString), f("enabled", database.KindBool),
			f("provider_id", database.KindString), f("model_id", database.KindString),
			f("updated_at", database.KindTime),
		},
	}
}
