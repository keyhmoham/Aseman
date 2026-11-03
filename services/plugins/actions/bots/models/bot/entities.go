package bot

import (
	"strings"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
)

// Entity contract keys for the per-bot entity storage.
//
// Every runtime artifact a bot needs — its backend binary, configuration,
// static files and frontend script — is stored under a runtime key instead of
// a fixed struct field. New entity types can be added at any time by simply
// using a new key, so the bot system can be upgraded without schema changes.
const (
	// EntityBackend holds the backend binary (or image reference) of the bot.
	EntityBackend = "backend"
	// EntitySpec holds the configuration / spec yaml of the bot.
	EntitySpec = "spec"
	// EntityFrontend holds the frontend script bundle (elpian) served to
	// clients when they launch the bot's UI.
	EntityFrontend = "frontend"
	// EntityResources holds the resource profile JSON.
	EntityResources = "resources"
	// EntityCost holds the cost model JSON.
	EntityCost = "cost"
	// EntityWidget holds the desk-widget DSL served for the bot's room widget.
	EntityWidget = "widget_dsl"
	// EntityBackendSecret holds optional deployment secrets (e.g. API keys).
	EntityBackendSecret = "backend_secret"
	// EntityStatic is a prefix; static files live under "static/<name>".
	EntityStatic = "static/"
	// EntityAssets is a prefix; other assets live under "assets/<name>".
	EntityAssets = "assets/"
	// EntityThemePack is the installable aseman.theme/v1 JSON for KindTheme.
	EntityThemePack = "static/theme.json"
)

// Entity is a single runtime artifact of a bot, keyed by a runtime contract
// key. The value is raw bytes so binaries, configs and scripts all fit.
type Entity struct {
	entity.Entity
	BotID identity.ID `db:"bot_id" json:"bot_id"`
	Key   string      `db:"key" json:"key"`
	Value []byte      `db:"value" json:"value"`
	Mime  string      `db:"mime" json:"mime,omitempty"`
	Size  int64       `db:"size" json:"size"`
}

// IsEntityFile reports whether a key addresses a file-like entity (a static
// asset or an arbitrary extension-based entity), as opposed to a well-known
// scalar contract key.
func IsEntityFile(key string) bool {
	return strings.HasPrefix(key, EntityStatic) || strings.HasPrefix(key, EntityAssets)
}

// EntityFileKey builds a static-file entity key: "static/<name>".
func EntityFileKey(name string) string { return EntityStatic + name }
