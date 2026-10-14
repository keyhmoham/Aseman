package tools

import (
	"context"

	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	"github.com/tradera/tradera/plugins/adapters/database/ports"
)

func filterEq(field string, value any) database.Filter {
	return database.Filter{Equal: map[string]any{field: value}}
}

// entity reads one of a tool bot's stored programs ("" when it has none).
func (s *Service) entity(ctx context.Context, botID, key string) (string, error) {
	id, err := identity.Parse(botID)
	if err != nil {
		return "", err
	}
	var e *bot.Entity
	if err := bridge.Invoke(ctx, s.K, "bots", "GetEntity", []any{ctx, id, key}, &e); err != nil {
		return "", err
	}
	if e == nil {
		return "", nil
	}
	return string(e.Value), nil
}

// putEntity stores one of a tool bot's programs as its owner.
func (s *Service) putEntity(ctx context.Context, owner identity.ID, botID identity.ID, key string, value []byte, mime string) error {
	return bridge.Invoke(ctx, s.K, "bots", "PutEntity", []any{ctx, owner, botID, key, value, mime})
}
