// Typed namespace facades resolve the current provider for every call.
package spaces

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	bots "github.com/aseman/aseman/plugins/actions/bots/dto"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/message/models/message"
	rt "github.com/aseman/aseman/plugins/actions/routines/models"
	"github.com/aseman/aseman/plugins/actions/usage/models"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

type botPortBridge struct{ K api.Kernel }

var _ BotPort = botPortBridge{}

func (p botPortBridge) BillAndRecordUsage(ctx context.Context, customer identity.ID, botID identity.ID, seconds int64, desc string, uc usage.UsageCtx) (usage.Delta, error) {
	var result0 usage.Delta
	err := bridge.Invoke(ctx, p.K, "bots", "BillAndRecordUsage", []any{ctx, customer, botID, seconds, desc, uc}, &result0)
	return result0, err
}
func (p botPortBridge) BillUsage(ctx context.Context, customer identity.ID, botID identity.ID, seconds int64, desc string) error {
	err := bridge.Invoke(ctx, p.K, "bots", "BillUsage", []any{ctx, customer, botID, seconds, desc})
	return err
}
func (p botPortBridge) CreateBot(ctx context.Context, owner identity.ID, req bots.CreateBotRequest) (*bot.Bot, error) {
	var result0 *bot.Bot
	err := bridge.Invoke(ctx, p.K, "bots", "CreateBot", []any{ctx, owner, req}, &result0)
	return result0, err
}
func (p botPortBridge) DeleteBot(ctx context.Context, caller identity.ID, botID identity.ID) error {
	err := bridge.Invoke(ctx, p.K, "bots", "DeleteBot", []any{ctx, caller, botID})
	return err
}
func (p botPortBridge) EnsureBalance(ctx context.Context, customer identity.ID, minCost int64) error {
	err := bridge.Invoke(ctx, p.K, "bots", "EnsureBalance", []any{ctx, customer, minCost})
	return err
}
func (p botPortBridge) EnsureFunds(ctx context.Context, customer identity.ID, botID identity.ID) error {
	err := bridge.Invoke(ctx, p.K, "bots", "EnsureFunds", []any{ctx, customer, botID})
	return err
}
func (p botPortBridge) EnsureVM(ctx context.Context, rec *bot.Bot) error {
	err := bridge.Invoke(ctx, p.K, "bots", "EnsureVM", []any{ctx, rec})
	return err
}
func (p botPortBridge) GetBot(ctx context.Context, id identity.ID) (*bot.Bot, error) {
	var result0 *bot.Bot
	err := bridge.Invoke(ctx, p.K, "bots", "GetBot", []any{ctx, id}, &result0)
	return result0, err
}
func (p botPortBridge) Resize(ctx context.Context, id identity.ID, res bot.ResourceProfile) (*bot.Bot, error) {
	var result *bot.Bot
	err := bridge.Invoke(ctx, p.K, "bots", "Resize", []any{ctx, id, res}, &result)
	return result, err
}
func (p botPortBridge) InstallAseman(ctx context.Context) (*bot.Bot, error) {
	var result0 *bot.Bot
	err := bridge.Invoke(ctx, p.K, "bots", "InstallAseman", []any{ctx}, &result0)
	return result0, err
}
func (p botPortBridge) Lifecycle(ctx context.Context, id identity.ID, op string) (*bot.Bot, error) {
	var result0 *bot.Bot
	err := bridge.Invoke(ctx, p.K, "bots", "Lifecycle", []any{ctx, id, op}, &result0)
	return result0, err
}
func (p botPortBridge) RecordDelta(ctx context.Context, actor identity.ID, botID identity.ID, d usage.Delta, uc usage.UsageCtx) error {
	err := bridge.Invoke(ctx, p.K, "bots", "RecordDelta", []any{ctx, actor, botID, d, uc})
	return err
}
func (p botPortBridge) RecordUsage(ctx context.Context, actor identity.ID, botID identity.ID, uc usage.UsageCtx) (usage.Delta, error) {
	var result0 usage.Delta
	err := bridge.Invoke(ctx, p.K, "bots", "RecordUsage", []any{ctx, actor, botID, uc}, &result0)
	return result0, err
}
func (p botPortBridge) SendMessage(ctx context.Context, botID identity.ID, body string, attachments []vmm.FileAttachment, history []vmm.ChatMessage) (string, error) {
	var result0 string
	err := bridge.Invoke(ctx, p.K, "bots", "SendMessage", []any{ctx, botID, body, attachments, history}, &result0)
	return result0, err
}
func (p botPortBridge) Widget(ctx context.Context, botID identity.ID) string {
	var result0 string
	err := bridge.Invoke(ctx, p.K, "bots", "Widget", []any{ctx, botID}, &result0)
	if err != nil {
		p.K.Logger().Warn("namespace bridge unavailable", "namespace", "bots", "method", "Widget", "error", err)
	}
	return result0
}

type messagePortBridge struct{ K api.Kernel }

var _ MessagePort = messagePortBridge{}

func (p messagePortBridge) SendPacket(ctx context.Context, from identity.ID, to identity.ID, body string, payload string) (*message.Packet, error) {
	var result0 *message.Packet
	err := bridge.Invoke(ctx, p.K, "message", "SendPacket", []any{ctx, from, to, body, payload}, &result0)
	return result0, err
}

type routineManagerBridge struct{ K api.Kernel }

var _ RoutineManager = routineManagerBridge{}

func (p routineManagerBridge) Create(ctx context.Context, spaceID identity.ID, roomID identity.ID, creator identity.ID, name string, typ rt.Type, target string, task string, delaySec int64, intervalSec int64) (*rt.Routine, error) {
	var result0 *rt.Routine
	err := bridge.Invoke(ctx, p.K, "routines", "Create", []any{ctx, spaceID, roomID, creator, name, typ, target, task, delaySec, intervalSec}, &result0)
	return result0, err
}
func (p routineManagerBridge) List(ctx context.Context, spaceID identity.ID, roomID identity.ID) ([]rt.Routine, error) {
	var result0 []rt.Routine
	err := bridge.Invoke(ctx, p.K, "routines", "List", []any{ctx, spaceID, roomID}, &result0)
	return result0, err
}
func (p routineManagerBridge) SetDaily(ctx context.Context, id identity.ID, at, tz string) (*rt.Routine, error) {
	var result0 *rt.Routine
	err := bridge.Invoke(ctx, p.K, "routines", "SetDaily", []any{ctx, id, at, tz}, &result0)
	return result0, err
}
func (p routineManagerBridge) Delete(ctx context.Context, id identity.ID) error {
	err := bridge.Invoke(ctx, p.K, "routines", "Delete", []any{ctx, id})
	return err
}

func (p routineManagerBridge) Get(ctx context.Context, id identity.ID) (*rt.Routine, error) {
	var result *rt.Routine
	err := bridge.Invoke(ctx, p.K, "routines", "Get", []any{ctx, id}, &result)
	return result, err
}

func (p routineManagerBridge) Update(ctx context.Context, id identity.ID, name, target, task string, delaySec, intervalSec int64) (*rt.Routine, error) {
	var result *rt.Routine
	err := bridge.Invoke(ctx, p.K, "routines", "Update", []any{ctx, id, name, target, task, delaySec, intervalSec}, &result)
	return result, err
}

func (p botPortBridge) Rebuild(ctx context.Context, id identity.ID, image string) (*bot.Bot, error) {
	var out *bot.Bot
	e := bridge.Invoke(ctx, p.K, "bots", "Rebuild", []any{ctx, id, image}, &out)
	return out, e
}
