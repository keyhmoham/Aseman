// Typed namespace facades resolve the current provider for every call.
package message

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

type attachmentResolverBridge struct{ K api.Kernel }

var _ AttachmentResolver = attachmentResolverBridge{}

func (p attachmentResolverBridge) ResolveAttachments(ctx context.Context, caller identity.ID, ids []string) ([]vmm.FileAttachment, error) {
	var result0 []vmm.FileAttachment
	err := bridge.Invoke(ctx, p.K, "spaces", "ResolveAttachments", []any{ctx, caller, ids}, &result0)
	return result0, err
}

type botMessengerBridge struct{ K api.Kernel }

var _ BotMessenger = botMessengerBridge{}

func (p botMessengerBridge) SendMessage(ctx context.Context, botID identity.ID, body string, attachments []vmm.FileAttachment, history []vmm.ChatMessage) (string, error) {
	var result0 string
	err := bridge.Invoke(ctx, p.K, "bots", "SendMessage", []any{ctx, botID, body, attachments, history}, &result0)
	return result0, err
}
func (p botMessengerBridge) BillUsage(ctx context.Context, customer identity.ID, botID identity.ID, seconds int64, desc string) error {
	err := bridge.Invoke(ctx, p.K, "bots", "BillUsage", []any{ctx, customer, botID, seconds, desc})
	return err
}
func (p botMessengerBridge) EnsureFunds(ctx context.Context, customer identity.ID, botID identity.ID) error {
	err := bridge.Invoke(ctx, p.K, "bots", "EnsureFunds", []any{ctx, customer, botID})
	return err
}
func (p botMessengerBridge) IsAseman(ctx context.Context, botID identity.ID) (bool, error) {
	var result0 bool
	err := bridge.Invoke(ctx, p.K, "bots", "IsAseman", []any{ctx, botID}, &result0)
	return result0, err
}
func (p botMessengerBridge) RunAseman(ctx context.Context, caller identity.ID, task string) (map[string]any, error) {
	var result0 map[string]any
	err := bridge.Invoke(ctx, p.K, "bots", "RunAseman", []any{ctx, caller, task}, &result0)
	return result0, err
}
