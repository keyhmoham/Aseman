// Package agentpolicy is what model-written code may call of the platform
// (agents through the harness gateway). Each call is dispatched as an account —
// the agent's, or the person's — so every action's own authorization still
// decides; this policy is the outer bound on top of it.
//
// Two scopes:
//   - Account: the person's own Aseman acts across the person's account.
//   - Space: a room agent acts inside one space: the space-bound namespaces
//     (never to create or list other spaces) and a few account-wide lookups.
//
// Never: node administration, authentication and identity, the plugin host,
// federation, the developer surface, model providers and their keys, usage
// and node settings, and moving money.
package agentpolicy

import "strings"

// Scope is where model-written code acts.
type Scope int

const (
	// Account acts across one person's account.
	Account Scope = iota
	// Space acts inside one space.
	Space
)

var deniedNamespaces = map[string]bool{
	"admin": true, "auth": true, "plugins": true, "federation": true, "developer": true,
	"usage": true, "llm": true, "settings": true, "hostaccess": true, "enterprise": true,
}

var deniedActions = map[string]bool{
	"finance.transfer": true, "finance.faucet": true, "finance.wallet_mint": true, "finance.pay_bot": true,
	"finance.pool_create": true, "finance.pool_consume": true, "finance.pool_free": true,
	"spaces.space_list_all": true,
	"users.accounts_list":   true, "users.account_update": true,
	"users.account_password": true, "users.account_delete": true,
	"users.account_create": true,
	"bots.entity_put":      true, "bots.entity_delete": true,
	"market.approve": true, "market.deny": true, "market.stats": true,
}

// spaceNamespaces are the space-bound namespaces.
var spaceNamespaces = map[string]bool{"spaces": true, "routines": true, "tools": true, "message": true}

// spaceGlobal are the account-wide actions a space scope may also call.
var spaceGlobal = map[string]bool{
	"users.search": true, "users.account_get": true, "users.dm_send": true, "users.dm_list": true,
	"market.catalog": true, "market.get": true, "market.recommend": true, "market.list": true,
	"themes.get": true, "talent.list_project": true,
}

// spaceDenied are actions of the space-bound namespaces that reach beyond one space.
var spaceDenied = map[string]bool{
	"spaces.space_create": true, "spaces.space_list": true, "spaces.space_search": true,
	"spaces.chat_list": true, "spaces.direct_open": true, "spaces.space_delete": true,
}

// Allows reports whether model code in scope may call namespace.action.
func Allows(scope Scope, name string) bool {
	name = strings.TrimSpace(name)
	ns, action, ok := strings.Cut(name, ".")
	if !ok || ns == "" || action == "" {
		return false
	}
	if deniedNamespaces[ns] || deniedActions[name] || strings.HasPrefix(action, "admin_") {
		return false
	}
	if scope == Account {
		return true
	}
	if spaceDenied[name] {
		return false
	}
	return spaceNamespaces[ns] || spaceGlobal[name]
}
