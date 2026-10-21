package spaces

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/identity"
	bots "github.com/aseman/aseman/plugins/actions/bots/dto"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	"github.com/aseman/aseman/plugins/actions/usage/models"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// BotPort defines only the operations this namespace consumes.
type BotPort interface {
	BillAndRecordUsage(ctx context.Context, customer, botID identity.ID, seconds int64, desc string, uc usage.UsageCtx) (usage.Delta, error)
	BillUsage(ctx context.Context, customer, botID identity.ID, seconds int64, desc string) error
	CreateBot(ctx context.Context, owner identity.ID, req bots.CreateBotRequest) (*bot.Bot, error)
	DeleteBot(ctx context.Context, caller, botID identity.ID) error
	EnsureBalance(ctx context.Context, customer identity.ID, minCost int64) error
	EnsureFunds(ctx context.Context, customer, botID identity.ID) error
	EnsureVM(ctx context.Context, rec *bot.Bot) error
	GetBot(ctx context.Context, id identity.ID) (*bot.Bot, error)
	Rebuild(ctx context.Context, id identity.ID, image string) (*bot.Bot, error)
	Resize(ctx context.Context, id identity.ID, res bot.ResourceProfile) (*bot.Bot, error)
	InstallAseman(ctx context.Context) (*bot.Bot, error)
	Lifecycle(ctx context.Context, id identity.ID, op string) (*bot.Bot, error)
	RecordDelta(ctx context.Context, actor, botID identity.ID, d usage.Delta, uc usage.UsageCtx) error
	RecordUsage(ctx context.Context, actor, botID identity.ID, uc usage.UsageCtx) (usage.Delta, error)
	SendMessage(ctx context.Context, botID identity.ID, body string, attachments []vmm.FileAttachment, history []vmm.ChatMessage) (string, error)
	Widget(ctx context.Context, botID identity.ID) string
}

// MessagePort resolves the current messaging module on each call.
type MessagePort interface {
	SendPacket(ctx context.Context, from, to identity.ID, body, payload string) (*message.Packet, error)
}
