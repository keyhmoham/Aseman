package deepagents

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Personal Aseman sessions act as the person. Authorization stays on each
// action (Dispatch as Kind user): anything the person could do in the app is
// reachable. Only node-admin / identity / metered-LLM surfaces are refused here.

// personalDeniedNamespaces are never callable through a personal gateway token.
var personalDeniedNamespaces = map[string]bool{
	"admin": true, "plugins": true, "usage": true,
}

// personalDeniedActions are specific actions refused even in allowed namespaces
// (node admin, provider keys, agentic-engine switch, admin account tools).
var personalDeniedActions = map[string]bool{
	"spaces.agent_engine_get": true, "spaces.agent_engine_set": true,
	"spaces.space_list_all": true, "spaces.admin_files": true,
	"spaces.admin_work_log": true, "spaces.admin_terminate_sandbox": true,
	"spaces.admin_sandboxes": true, "spaces.admin_storage": true,
	"spaces.admin_chat_reports": true, "spaces.admin_chat_report_resolve": true,
	"llm.llm_provider_set": true, "llm.llm_provider_delete": true,
	"llm.llm_import_vercel": true, "llm.llm_providers_list": true,
	"users.accounts_list": true, "users.account_update": true,
	"users.account_password": true, "users.account_delete": true,
	"users.account_create": true,
	"auth.login": true, "auth.register": true, "auth.logout": true,
	"auth.password_forgot": true, "auth.password_reset": true,
	"auth.oauth_google": true, "auth.oauth_apple": true,
	"bots.entity_put": true, "bots.entity_delete": true,
	"market.approve": true, "market.deny": true, "market.stats": true,
}

// openPersonal mints a person-scoped gateway session for personal Aseman chat
// under a CLI engine (OpenCode, DeepSeek Harness). The runtime presents the
// token like a room turn; serveCall dispatches as the person (Kind user), with
// no single-space lock.
func (a *Adapter) openPersonal(ctx context.Context, person identity.ID) (*session, error) {
	if person.IsZero() {
		return nil, errs.InvalidArgument("personal chat needs a person")
	}
	if err := a.ensureRuntime(ctx); err != nil {
		return nil, err
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return nil, err
	}
	token := hex.EncodeToString(raw)
	base := context.WithoutCancel(ctx)
	base = vmm.WithExecution(base, vmm.Execution{ActorID: person.String()})
	s := &session{
		token: token, account: person, personal: true,
		base: base, started: time.Now(),
		sentMessages: map[string]bool{}, attachments: map[string]bool{},
	}
	a.mu.Lock()
	a.sessions[s.token] = s
	a.mu.Unlock()
	return s, nil
}

func (s *session) allows(name string) bool {
	if !s.personal {
		return allowedActions[name]
	}
	return personalAllows(name)
}

// personalAllows reports whether a person-scoped session may call name.
// The action itself still enforces the caller's permissions.
func personalAllows(name string) bool {
	name = strings.TrimSpace(name)
	if name == "" || !strings.Contains(name, ".") {
		return false
	}
	ns, _, _ := strings.Cut(name, ".")
	if personalDeniedNamespaces[ns] {
		return false
	}
	if personalDeniedActions[name] {
		return false
	}
	// Metered LLM proxy / decision endpoints are not platform_call actions,
	// but refuse any stray llm.* chat completions style names.
	if ns == "llm" && (strings.Contains(name, "chat") || strings.Contains(name, "complet")) {
		return false
	}
	return true
}
