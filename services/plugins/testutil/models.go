// Package testutil assembles schemas only for cross-namespace unit fixtures.
package testutil

import (
	authschema "github.com/tradera/tradera/plugins/actions/auth/schema"
	botsschema "github.com/tradera/tradera/plugins/actions/bots/schema"
	developer "github.com/tradera/tradera/plugins/actions/developer/models"
	federationschema "github.com/tradera/tradera/plugins/actions/federation/schema"
	financeschema "github.com/tradera/tradera/plugins/actions/finance/schema"
	llm "github.com/tradera/tradera/plugins/actions/llm/models"
	"github.com/tradera/tradera/plugins/actions/market/models"
	messageschema "github.com/tradera/tradera/plugins/actions/message/schema"
	posts "github.com/tradera/tradera/plugins/actions/posts/models"
	routines "github.com/tradera/tradera/plugins/actions/routines/models"
	spacesschema "github.com/tradera/tradera/plugins/actions/spaces/schema"
	supportschema "github.com/tradera/tradera/plugins/actions/support/schema"
	"github.com/tradera/tradera/plugins/actions/usage/models"
	usersschema "github.com/tradera/tradera/plugins/actions/users/schema"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

func Models() []database.Model {
	var models []database.Model
	models = append(models, authschema.Models()...)
	models = append(models, spacesschema.Models()...)
	models = append(models, messageschema.Models()...)
	models = append(models, financeschema.Models()...)
	models = append(models, botsschema.Models()...)
	models = append(models, usersschema.Models()...)
	models = append(models, federationschema.Models()...)
	models = append(models, supportschema.Models()...)
	models = append(models, routines.Models()...)
	models = append(models, posts.Models()...)
	models = append(models, market.Models()...)
	models = append(models, usage.Models()...)
	models = append(models, llm.Models()...)
	models = append(models, developer.Models()...)
	seen := make(map[string]bool)
	unique := make([]database.Model, 0, len(models))
	for _, m := range models {
		if !seen[m.Name] {
			seen[m.Name] = true
			unique = append(unique, m)
		}
	}
	return unique
}
