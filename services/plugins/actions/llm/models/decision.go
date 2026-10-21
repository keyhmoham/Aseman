package llmprovider

import (
	"time"

	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Decision is the node's decision model setting, chosen by the admin: one
// model of an enabled provider that answers the agents' decisions (which
// tools a turn needs, which agent takes a task, whether work is done). Off,
// every agent decides with its own model, as without one.
type Decision struct {
	ID         string `db:"id" json:"-"`
	Enabled    bool   `db:"enabled" json:"enabled"`
	ProviderID string `db:"provider_id" json:"provider_id"`
	ModelID    string `db:"model_id" json:"model_id"`
	// AutoApprove lets the decision model approve the low-risk calls of tools
	// agents must ask people about (interrupt_on); off, people approve every one.
	AutoApprove bool      `db:"auto_approve" json:"auto_approve"`
	UpdatedAt   time.Time `db:"updated_at" json:"updated_at"`
}

func llmDecision() database.Model {
	return database.Model{
		Name:  "llm_decision",
		Table: "llm_decision",
		Fields: []database.Field{
			f("id", database.KindString), f("enabled", database.KindBool),
			f("provider_id", database.KindString), f("model_id", database.KindString),
			f("auto_approve", database.KindBool),
			f("updated_at", database.KindTime),
		},
	}
}
