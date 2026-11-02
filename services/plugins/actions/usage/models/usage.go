package usage

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	metrics "github.com/aseman/aseman/plugins/actions/usage/models/usage"
)

// Usage is one metered LLM token consumption event, attributed to the space,
// room and bot that produced it and correlated to a request.
type Usage struct {
	entity.Entity
	SpaceID identity.ID `db:"space_id" json:"space_id"`
	RoomID  identity.ID `db:"room_id" json:"room_id,omitempty"`
	BotID   identity.ID `db:"bot_id" json:"bot_id,omitempty"`
	// BotName is the human-readable agent name (or "aseman").
	BotName string `db:"bot_name" json:"bot_name,omitempty"`
	// ActorID is the account whose request consumed the tokens.
	ActorID identity.ID `db:"actor_id" json:"actor_id"`
	// RequestID correlates every usage event of one user request.
	RequestID string `db:"request_id" json:"request_id,omitempty"`
	// Kind is ask | mention | message | sandbox | workflow.
	Provider  string `db:"provider" json:"provider,omitempty"`
	Model     string `db:"model" json:"model,omitempty"`
	Kind      string `db:"kind" json:"kind,omitempty"`
	TokensIn  int64  `db:"tokens_in" json:"tokens_in"`
	TokensOut int64  `db:"tokens_out" json:"tokens_out"`
	Images    int64  `db:"images" json:"images,omitempty"`
	// Cost is the credits charged for this usage (best-effort; 0 when the node
	// has no priced provider for the bot's model).
	Cost int64 `db:"cost" json:"cost,omitempty"`
	// DecisionIn and DecisionOut are the tokens the node's decision model used
	// for this request's decisions, and Decision what it charged (ledger
	// units, already inside Cost). All zero when the decision model was not
	// called.
	DecisionIn  int64 `db:"decision_in" json:"decision_in,omitempty"`
	DecisionOut int64 `db:"decision_out" json:"decision_out,omitempty"`
	Decision    int64 `db:"decision" json:"decision,omitempty"`
	// ImageCount, ImageIn and ImageOut are the images the node's image model
	// made for this request and the tokens it reported, ImageModel which model
	// ("Provider / model"). What they cost is Images (inside Cost).
	ImageCount int64  `db:"image_count" json:"image_count,omitempty"`
	ImageIn    int64  `db:"image_in" json:"image_in,omitempty"`
	ImageOut   int64  `db:"image_out" json:"image_out,omitempty"`
	ImageModel string `db:"image_model" json:"image_model,omitempty"`
}

// MemoryUsage is one settlement of what a project's agent memory used: the
// memory models are charged to the project in batches, not per request, so
// this is a project-level line and is kept apart from the per-request usage.
type MemoryUsage struct {
	entity.Entity
	SpaceID identity.ID `db:"space_id" json:"space_id"`
	// Tokens is every token of the settled calls, TokensIn the input part.
	Tokens   int64 `db:"tokens" json:"tokens"`
	TokensIn int64 `db:"tokens_in" json:"tokens_in"`
	// Cost is what was charged, in ledger units.
	Cost int64 `db:"cost" json:"cost"`
}

type Delta = metrics.Delta
type UsageCtx = metrics.UsageCtx

const (
	KindAsk      = metrics.KindAsk
	KindChat     = metrics.KindChat
	KindMention  = metrics.KindMention
	KindMessage  = metrics.KindMessage
	KindSandbox  = metrics.KindSandbox
	KindWorkflow = metrics.KindWorkflow
)

var WithRequestID = metrics.WithRequestID
var RequestIDFrom = metrics.RequestIDFrom

// CreatedAt returns the row's creation time (entity.CreatedAt).
func (u *Usage) CreatedAt() time.Time { return u.Entity.CreatedAt }
