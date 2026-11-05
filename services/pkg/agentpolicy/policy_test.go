package agentpolicy

import "testing"

func TestTheTwoScopes(t *testing.T) {
	for _, name := range []string{"spaces.message_send", "spaces.space_create", "themes.apply", "posts.post_create", "finance.wallet_get", "routines.create"} {
		if !Allows(Account, name) {
			t.Errorf("account scope refused %s", name)
		}
	}
	for _, name := range []string{"admin.health", "auth.login", "finance.transfer", "llm.llm_provider_set", "spaces.admin_storage", "admin.plugins_list", "tools.gadget_remove", "x"} {
		if Allows(Account, name) || Allows(Space, name) {
			t.Errorf("%s is allowed", name)
		}
	}
	for _, name := range []string{"spaces.message_send", "spaces.room_create", "routines.create", "tools.gadget_list", "users.search", "market.catalog"} {
		if !Allows(Space, name) {
			t.Errorf("space scope refused %s", name)
		}
	}
	for _, name := range []string{"spaces.space_create", "spaces.direct_open", "posts.post_create", "themes.apply", "finance.wallet_get", "bots.bot_list"} {
		if Allows(Space, name) {
			t.Errorf("space scope allowed %s", name)
		}
	}
}
