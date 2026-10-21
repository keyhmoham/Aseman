// Typed namespace facades resolve the current provider for every call.
package bots

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
	dtoLLM "github.com/aseman/aseman/plugins/actions/llm/dto"
	"github.com/aseman/aseman/plugins/actions/llm/models"
	"github.com/aseman/aseman/plugins/actions/usage/models"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

type attachmentResolverBridge struct{ K api.Kernel }

var _ AttachmentResolver = attachmentResolverBridge{}

func (p attachmentResolverBridge) ResolveAttachments(ctx context.Context, caller identity.ID, ids []string) ([]vmm.FileAttachment, error) {
	var result0 []vmm.FileAttachment
	err := bridge.Invoke(ctx, p.K, "spaces", "ResolveAttachments", []any{ctx, caller, ids}, &result0)
	return result0, err
}

type agentAskerBridge struct{ K api.Kernel }

var _ AgentAsker = agentAskerBridge{}

func (p agentAskerBridge) AskDirect(ctx context.Context, caller, botID identity.ID, body string, attachments []vmm.FileAttachment) (string, error) {
	var result0 string
	err := bridge.Invoke(ctx, p.K, "spaces", "AskDirect", []any{ctx, caller, botID, body, attachments}, &result0)
	return result0, err
}

type billerBridge struct{ K api.Kernel }

var _ Biller = billerBridge{}

func (p billerBridge) Charge(ctx context.Context, customer identity.ID, botOwner identity.ID, nodeOwner identity.ID, amount int64, desc string) error {
	err := bridge.Invoke(ctx, p.K, "finance", "Charge", []any{ctx, customer, botOwner, nodeOwner, amount, desc})
	return err
}
func (p billerBridge) EnsureFunds(ctx context.Context, customer identity.ID, minCost int64) error {
	err := bridge.Invoke(ctx, p.K, "finance", "EnsureFunds", []any{ctx, customer, minCost})
	return err
}

type llmPortBridge struct{ K api.Kernel }

var _ LLMPort = llmPortBridge{}

func (p llmPortBridge) Resolve(ctx context.Context, provider string, model string) (*llmprovider.Provider, llmprovider.Model, error) {
	var result0 *llmprovider.Provider
	var result1 llmprovider.Model
	err := bridge.Invoke(ctx, p.K, "llm", "Resolve", []any{ctx, provider, model}, &result0, &result1)
	return result0, result1, err
}
func (p llmPortBridge) PriceFor(ctx context.Context, provider string, model string) (dtoLLM.Price, error) {
	var result0 dtoLLM.Price
	err := bridge.Invoke(ctx, p.K, "llm", "PriceFor", []any{ctx, provider, model}, &result0)
	return result0, err
}

type lineChargerBridge struct{ K api.Kernel }

var _ LineCharger = lineChargerBridge{}

func (p lineChargerBridge) ChargeLines(ctx context.Context, customer identity.ID, desc string, lines []wallet.ChargeLine) error {
	err := bridge.Invoke(ctx, p.K, "finance", "ChargeLines", []any{ctx, customer, desc, lines})
	return err
}

type usageRecorderBridge struct{ K api.Kernel }

var _ UsageRecorder = usageRecorderBridge{}

func (p usageRecorderBridge) Record(arg0 context.Context, arg1 *usage.Usage) error {
	err := bridge.Invoke(arg0, p.K, "usage", "Record", []any{arg0, arg1})
	return err
}
