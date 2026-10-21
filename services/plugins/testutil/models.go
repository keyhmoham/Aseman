// Package testutil assembles schemas only for cross-namespace unit fixtures.
package testutil

import (
	authschema "github.com/aseman/aseman/plugins/actions/auth/schema"
	botsschema "github.com/aseman/aseman/plugins/actions/bots/schema"
	developer "github.com/aseman/aseman/plugins/actions/developer/models"
	federationschema "github.com/aseman/aseman/plugins/actions/federation/schema"
	financeschema "github.com/aseman/aseman/plugins/actions/finance/schema"
	llm "github.com/aseman/aseman/plugins/actions/llm/models"
	"github.com/aseman/aseman/plugins/actions/market/models"
	messageschema "github.com/aseman/aseman/plugins/actions/message/schema"
	posts "github.com/aseman/aseman/plugins/actions/posts/models"
	routines "github.com/aseman/aseman/plugins/actions/routines/models"
	spacesschema "github.com/aseman/aseman/plugins/actions/spaces/schema"
	supportschema "github.com/aseman/aseman/plugins/actions/support/schema"
	"github.com/aseman/aseman/plugins/actions/usage/models"
	usersschema "github.com/aseman/aseman/plugins/actions/users/schema"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
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
