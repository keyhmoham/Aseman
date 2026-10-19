// Package usage defines shared invocation attribution and metric values. Every metered request
// (a direct ask, a room-chat mention, a tradera orchestration step) records a
// Usage row attributed to the space, room, bot and request that consumed the
// tokens, so spending can be rolled up per space, per room chat and per agent.
package usage

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/identity"
)

// requestIDCtxKey carries the current request id in the context so nested agent
// dispatches (e.g. tradera's team steps) share one correlation id across the
// spaces and workflow services.
type requestIDCtxKey struct{}

// WithRequestID returns a context carrying [requestID].
func WithRequestID(ctx context.Context, requestID string) context.Context {
	if requestID == "" {
		return ctx
	}
	return context.WithValue(ctx, requestIDCtxKey{}, requestID)
}

// RequestIDFrom returns the request id stored in ctx ("" when absent).
func RequestIDFrom(ctx context.Context) string {
	if v, ok := ctx.Value(requestIDCtxKey{}).(string); ok {
		return v
	}
	return ""
}

// Kind labels the interaction that produced the usage.
const (
	KindAsk      = "ask"      // direct ask to an agent
	KindChat     = "chat"     // an agent answering in a person's chat (no room)
	KindMention  = "mention"  // agent triggered by a room chat mention
	KindMessage  = "message"  // direct message to a bot
	KindSandbox  = "sandbox"  // shared sandbox command execution
	KindWorkflow = "workflow" // tradera orchestration (its own brain)
)

// UsageCtx attributes a metered request: where it happened (space/room), which
// kind of interaction it was and which request it belongs to.
type UsageCtx struct {
	SpaceID   identity.ID
	RoomID    identity.ID
	BotName   string
	RequestID string
	Kind      string
}

// Delta is a metered token consumption window (the tokens one request used).
type Delta struct {
	TokensIn  int64
	TokensOut int64
	// Images is the priced cost of generated images in ledger units (the image
	// model's price per image and/or per token), not a count of images.
	Images int64
	// ImageCount, ImageIn and ImageOut are what the image model made and the
	// tokens it reported (0 for a model priced per image), and ImageModel which
	// model ("Provider / model"), for the admin log.
	ImageCount int64
	ImageIn    int64
	ImageOut   int64
	ImageModel string
	// Decision is what the node's decision model charged for the agent's
	// decisions (tool selection and checks), already priced in ledger units
	// with the decision model's own token prices.
	Decision int64
	// DecisionIn and DecisionOut are the decision model's own tokens (not part
	// of TokensIn/TokensOut, which are the agent model's), for the admin log.
	DecisionIn  int64
	DecisionOut int64
	Cost        int64
}

// Zero reports whether no tokens or images were consumed.
func (d Delta) Zero() bool {
	return d.TokensIn <= 0 && d.TokensOut <= 0 && d.Images <= 0 && d.Decision <= 0 && d.DecisionIn <= 0 && d.DecisionOut <= 0
}

// Summary renders a compact, human-readable usage footer for an agent's reply,
// e.g. "⛽ LLM usage · 1,234 in / 567 out tokens · ≈5 credits" (cost is in ledger units).
func (d Delta) Summary() string {
	if d.Zero() {
		return ""
	}
	var b []byte
	b = append(b, "⛽ **LLM usage** · "...)
	if d.TokensIn > 0 {
		b = appendInt(b, d.TokensIn)
		b = append(b, " in"...)
	}
	if d.TokensOut > 0 {
		if d.TokensIn > 0 {
			b = append(b, " / "...)
		}
		b = appendInt(b, d.TokensOut)
		b = append(b, " out"...)
	}
	if d.Images > 0 {
		if d.TokensIn > 0 || d.TokensOut > 0 {
			b = append(b, " · "...)
		}
		// Images holds what the images cost (already priced, in ledger units,
		// part of Cost), not how many there were: show that images were made.
		b = append(b, "images"...)
	}
	if d.Cost > 0 {
		// Cost is in ledger units (1,000,000 per USD); people see credits
		// (100 per USD), and anything under one credit as "<1".
		const unitsPerCredit = 10_000
		if d.Cost < unitsPerCredit {
			b = append(b, " · <1 credit"...)
		} else {
			// To a tenth of a credit, rounded: 18,000 units is "≈1.8 credits",
			// not "≈1" (cutting the fraction off hid almost half of it).
			tenths := (d.Cost + unitsPerCredit/20) / (unitsPerCredit / 10)
			b = append(b, " · ≈"...)
			b = appendInt(b, tenths/10)
			if tenths%10 != 0 {
				b = append(b, '.')
				b = appendInt(b, tenths%10)
			}
			b = append(b, " credits"...)
		}
	}
	return string(b)
}

func appendInt(b []byte, n int64) []byte {
	if n == 0 {
		return append(b, '0')
	}
	if n < 0 {
		b = append(b, '-')
		n = -n
	}
	var tmp [20]byte
	i := len(tmp)
	for n > 0 {
		i--
		tmp[i] = byte('0' + n%10)
		n /= 10
	}
	return append(b, tmp[i:]...)
}
