package bots

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
)

func (p billerBridge) ChargeLines(ctx context.Context, customer identity.ID, desc string, lines []wallet.ChargeLine) error {
	return lineChargerBridge{K: p.K}.ChargeLines(ctx, customer, desc, lines)
}
