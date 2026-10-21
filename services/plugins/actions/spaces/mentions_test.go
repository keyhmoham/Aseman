package spaces

import (
	"context"
	"sync"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/usage/models"
)

// mentionBots skips VM rebuilds for delivery tests and records what agent
// turns are billed.
type mentionBots struct {
	BotPort
	billed *billLog
	// fundsErr, when set, is what EnsureFunds answers (the wallet or the
	// project's budget is spent).
	fundsErr *error
}

func (f mentionBots) EnsureFunds(ctx context.Context, customer, botID identity.ID) error {
	if f.fundsErr != nil && *f.fundsErr != nil {
		return *f.fundsErr
	}
	return nil
}

type billLog struct {
	mu    sync.Mutex
	turns []billedTurn
}

type billedTurn struct {
	payer, bot identity.ID
	seconds    int64
}

func (l *billLog) all() []billedTurn {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]billedTurn(nil), l.turns...)
}

func (f mentionBots) BillAndRecordUsage(_ context.Context, customer, botID identity.ID, seconds int64, _ string, _ usage.UsageCtx) (usage.Delta, error) {
	if f.billed != nil {
		f.billed.mu.Lock()
		f.billed.turns = append(f.billed.turns, billedTurn{customer, botID, seconds})
		f.billed.mu.Unlock()
	}
	return usage.Delta{}, nil
}

func (f mentionBots) EnsureVM(context.Context, *bot.Bot) error { return nil }
func (f mentionBots) RecordUsage(context.Context, identity.ID, identity.ID, usage.UsageCtx) (usage.Delta, error) {
	return usage.Delta{}, nil
}
