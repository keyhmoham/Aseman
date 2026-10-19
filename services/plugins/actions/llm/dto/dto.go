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

// Offering is one model of one enabled provider as the developer API serves
// it: the endpoint to call, the key to call it with (which never leaves the
// node) and the prices, in ledger units per 1M tokens (or per image).
type Offering struct {
	// Provider is the id of the provider row; Slug is what a developer's
	// request names it by (`vertex`, `openrouter`).
	Provider  string
	Slug      string
	Name      string
	Kind      string
	IsDefault bool
	// Owner is the account that owns the provider's key and is paid for usage.
	Owner identity.ID
	// BaseURL has any placeholder already resolved.
	BaseURL string
	APIKey  string
	// Model is the id the provider calls the model; Label the name the admin
	// (or the source catalog) gave it, if any.
	Model string
	Label string
	// Type is "chat", "decision", "embedding", "image", "video", "speech",
	// "transcription" or "rerank".
	Type          string
	InputPrice    float64
	OutputPrice   float64
	ContextWindow int
	// Tags and Inputs are what the model's source catalog reports (Vercel AI
	// Gateway: tool-use, vision, reasoning, …; text, image, pdf, …); empty for
	// a model added by hand.
	Tags   []string
	Inputs []string
	// Unit prices, in ledger units: per image, per second (of video, by
	// resolution where it differs, or of transcribed audio), per character of
	// speech and per reranking search.
	PerImage     float64
	PerSecond    float64
	PerSecondBy  map[string]float64
	PerCharacter float64
	PerSearch    float64
}
