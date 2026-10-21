package developer

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
	"github.com/aseman/aseman/plugins/actions/llm/dto"
)

type financeBridge struct{ K api.Kernel }

var _ Finance = financeBridge{}

func (p financeBridge) EnsureWallet(ctx context.Context, owner identity.ID) error {
	return bridge.Invoke(ctx, p.K, "finance", "EnsureWallet", []any{ctx, owner})
}
func (p financeBridge) GetWallet(ctx context.Context, owner identity.ID) (*wallet.Wallet, error) {
	var out *wallet.Wallet
	err := bridge.Invoke(ctx, p.K, "finance", "GetWallet", []any{ctx, owner}, &out)
	return out, err
}
func (p financeBridge) Transfer(ctx context.Context, from, to identity.ID, amount int64) (*wallet.LedgerEntry, error) {
	var out *wallet.LedgerEntry
	err := bridge.Invoke(ctx, p.K, "finance", "Transfer", []any{ctx, from, to, amount}, &out)
	return out, err
}
func (p financeBridge) EnsureFunds(ctx context.Context, customer identity.ID, minCost int64) error {
	return bridge.Invoke(ctx, p.K, "finance", "EnsureFunds", []any{ctx, customer, minCost})
}
func (p financeBridge) ChargeLines(ctx context.Context, customer identity.ID, desc string, lines []wallet.ChargeLine) error {
	return bridge.Invoke(ctx, p.K, "finance", "ChargeLines", []any{ctx, customer, desc, lines})
}

type providersBridge struct{ K api.Kernel }

var _ Providers = providersBridge{}

func (p providersBridge) Offerings(ctx context.Context) ([]dto.Offering, error) {
	var out []dto.Offering
	err := bridge.Invoke(ctx, p.K, "llm", "Offerings", []any{ctx}, &out)
	return out, err
}

type infraBridge struct{ K api.Kernel }

var _ Infra = infraBridge{}

func (p infraBridge) Machine(ctx context.Context) (MachineSettings, error) {
	var out MachineSettings
	err := bridge.Invoke(ctx, p.K, "settings", "Machine", []any{ctx}, &out)
	return out, err
}
func (p infraBridge) Rate(ctx context.Context) (ComputerRate, error) {
	var out struct {
		Sandbox ComputerRate `json:"sandbox"`
	}
	err := bridge.Invoke(ctx, p.K, "settings", "Pricing", []any{ctx}, &out)
	return out.Sandbox, err
}
func (p infraBridge) StoragePrice(ctx context.Context) (int64, error) {
	var out struct {
		Storage int64 `json:"storage_gb_month"`
	}
	err := bridge.Invoke(ctx, p.K, "settings", "Pricing", []any{ctx}, &out)
	return out.Storage, err
}
func (p infraBridge) NodeOwner(ctx context.Context) identity.ID {
	var out identity.ID
	if err := bridge.Invoke(ctx, p.K, "bots", "NodeOwnerID", []any{ctx}, &out); err != nil {
		return identity.ID{}
	}
	return out
}
