package spaces

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/usage/models"
)

// MeterBotUsage meters a bot's LLM token consumption since its last recorded
// usage and records it (no billing). Used by the orchestrator for the agents it
// dispatches inside a workflow.
func (s *Service) MeterBotUsage(ctx context.Context, spaceID, roomID, botID, actor identity.ID, requestID, kind, botName string) (usage.Delta, error) {
	if s.Bots == nil {
		return usage.Delta{}, nil
	}
	uc := usage.UsageCtx{SpaceID: spaceID, RoomID: roomID, BotName: botName, RequestID: requestID, Kind: kind}
	return s.Bots.RecordUsage(ctx, actor, botID, uc)
}

// RecordBotUsage records a fixed usage delta (aseman's own orchestrator
// brain usage, which has no bot VM meter).
func (s *Service) RecordBotUsage(ctx context.Context, spaceID, roomID, botID, actor identity.ID, requestID, kind, botName string, d usage.Delta) error {
	if s.Bots == nil {
		return nil
	}
	uc := usage.UsageCtx{SpaceID: spaceID, RoomID: roomID, BotName: botName, RequestID: requestID, Kind: kind}
	return s.Bots.RecordDelta(ctx, actor, botID, d, uc)
}
