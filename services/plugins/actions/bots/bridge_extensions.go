package bots

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/finance/models/wallet"
)

func (p billerBridge) ChargeLines(ctx context.Context, customer identity.ID, desc string, lines []wallet.ChargeLine) error {
	return lineChargerBridge{K: p.K}.ChargeLines(ctx, customer, desc, lines)
}
