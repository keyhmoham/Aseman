// Typed namespace facades resolve the current provider for every call.
package routine

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

type spacesPortBridge struct{ K api.Kernel }

var _ SpacesPort = spacesPortBridge{}

func (p spacesPortBridge) AskBot(ctx context.Context, spaceID identity.ID, botID identity.ID, body string, attachments []vmm.FileAttachment, history []vmm.ChatMessage) (string, error) {
	var result0 string
	err := bridge.Invoke(ctx, p.K, "spaces", "AskBot", []any{ctx, spaceID, botID, body, attachments, history}, &result0)
	return result0, err
}
func (p spacesPortBridge) SandboxExec(ctx context.Context, spaceID identity.ID, command string) (string, error) {
	var result0 string
	err := bridge.Invoke(ctx, p.K, "spaces", "SandboxExec", []any{ctx, spaceID, command}, &result0)
	return result0, err
}
