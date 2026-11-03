package harness

import (
	"context"
	"net/http"
	"strings"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// PersonalChat implements vmm.PersonalChatter: one answer of Aseman, the
// person's own assistant (the assistant chat and Talk), on the agent runtime.
// It runs through a person-scoped gateway session: its /llm is the assistant's
// platform model (the tokens metered into chat.Usage and billed to the
// person), its memory is the person's, and with WithTools its actions are the
// person's own — app-wide, with the person's access, within the agents'
// policy (policy.go).
func (a *Adapter) PersonalChat(ctx context.Context, chat vmm.PersonalChat) (string, error) {
	person, err := identity.Parse(strings.TrimSpace(chat.PersonID))
	if err != nil || person.IsZero() {
		return "", errs.InvalidArgument("personal chat needs person_id")
	}
	s, err := a.openPersonal(ctx, person)
	if err != nil {
		return "", err
	}
	defer a.close(s)
	s.chat = &Spec{Name: "Aseman", Provider: chat.Provider, Model: chat.Model}
	if chat.Usage != nil {
		defer func() {
			s.mu.Lock()
			chat.Usage.TokensIn, chat.Usage.TokensOut = s.tokIn, s.tokOut
			s.mu.Unlock()
		}()
	}
	window := 0
	if a.platform != nil {
		if provider, err := a.platform.ResolveChat(ctx, chat.Provider, chat.Model); err == nil {
			window = provider.ContextWindow
		}
	}
	body := map[string]any{
		"system":         chat.System,
		"messages":       chat.Messages,
		"thread_id":      strings.TrimSpace(chat.ThreadID),
		"with_tools":     chat.WithTools,
		"gateway":        a.nodeURL + gatewayPrefix,
		"token":          s.token,
		"account_id":     person.String(),
		"context_window": window,
	}
	var out struct {
		Reply      string      `json:"reply"`
		Status     string      `json:"status"`
		Error      string      `json:"error"`
		Transcript *transcript `json:"transcript,omitempty"`
	}
	if err := a.call(ctx, http.MethodPost, "/v1/chat", body, &out); err != nil {
		return "", err
	}
	s.settle(ctx)
	if out.Error != "" && strings.TrimSpace(out.Reply) == "" {
		return "", errs.New(errs.CodeUnavailable, out.Error)
	}
	a.learnLater(s, out.Transcript)
	return strings.TrimSpace(out.Reply), nil
}
