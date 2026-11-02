package deepagents

import (
	"context"
	"net/http"
	"strings"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// PersonalChat implements vmm.PersonalChatter: one Aseman self-chat / Talk
// answer under the node's agentic engine. When the engine is OpenCode, the
// runtime uses a free OpenCode model. WithTools mints a person-scoped gateway
// session so MCP space tools work the same way as on a room turn.
func (a *Adapter) PersonalChat(ctx context.Context, chat vmm.PersonalChat) (string, error) {
	engine := "deepagents"
	if a.platform != nil {
		if e, err := a.platform.AgentEngine(ctx); err == nil && e != "" {
			engine = e
		}
	}
	if engine != "opencode" {
		return "", errs.New(errs.CodeUnavailable, "personal chat through the runtime is only used when the agentic engine is OpenCode")
	}
	if err := a.ensureRuntime(ctx); err != nil {
		return "", err
	}

	body := map[string]any{
		"agent_engine": engine,
		"system":       chat.System,
		"messages":     chat.Messages,
		"thread_id":    strings.TrimSpace(chat.ThreadID),
		"with_tools":   chat.WithTools,
	}

	if chat.WithTools {
		person, err := identity.Parse(strings.TrimSpace(chat.PersonID))
		if err != nil || person.IsZero() {
			return "", errs.InvalidArgument("personal chat with tools needs person_id")
		}
		s, err := a.openPersonal(ctx, person)
		if err != nil {
			return "", err
		}
		defer a.close(s)
		body["gateway"] = a.nodeURL + gatewayPrefix
		body["token"] = s.token
		body["account_id"] = person.String()
	}

	var out struct {
		Reply  string `json:"reply"`
		Status string `json:"status"`
		Error  string `json:"error"`
	}
	if err := a.call(ctx, http.MethodPost, "/v1/chat", body, &out); err != nil {
		return "", err
	}
	if out.Error != "" && strings.TrimSpace(out.Reply) == "" {
		return "", errs.New(errs.CodeUnavailable, out.Error)
	}
	return strings.TrimSpace(out.Reply), nil
}
