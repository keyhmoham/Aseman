package dto

import (
	"math"

	"github.com/tradera/tradera/internal/plugins/identity"
)

type Price struct {
	ProviderID  identity.ID
	Payee       identity.ID // owner of the API key
	InputPrice  float64     // credits per 1M input tokens
	OutputPrice float64     // credits per 1M output tokens
}

func (p Price) TokenCost(tokensIn, tokensOut int64) int64 {
	if tokensIn <= 0 && tokensOut <= 0 {
		return 0
	}
	c := (float64(tokensIn)*p.InputPrice + float64(tokensOut)*p.OutputPrice) / 1e6
	if c <= 0 {
		return 0
	}
	return int64(math.Ceil(c - 1e-9))
}
