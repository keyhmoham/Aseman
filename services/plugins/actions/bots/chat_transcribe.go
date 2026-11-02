package bots

import (
	"context"
	"strings"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	usage "github.com/aseman/aseman/plugins/actions/usage/models"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// ChatTranscribe has the node's transcription model turn spoken audio into text
// for customer (a live voice chat with their Aseman), and bills them at that
// model's per-second prices as their use of no room.
func (s *Service) ChatTranscribe(ctx context.Context, customer, botID identity.ID, audio []byte, mime string) (*vmm.Transcription, error) {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return nil, err
	}
	if err := s.EnsureFunds(ctx, customer, botID); err != nil {
		return nil, err
	}
	var out *vmm.Transcription
	if err := bridge.Invoke(ctx, s.K, "llm", "Transcribe", []any{ctx, audio, mime}, &out); err != nil {
		return nil, err
	}
	if out == nil || strings.TrimSpace(out.Text) == "" {
		return nil, errs.New(errs.CodeUnavailable, "the transcription model made no text")
	}
	if err := s.billChatTranscription(ctx, customer, rec, out); err != nil {
		s.L.Warn("chat transcription not billed", "bot", rec.ID.String(), "error", err)
	}
	return out, nil
}

func (s *Service) billChatTranscription(ctx context.Context, customer identity.ID, rec *bot.Bot, t *vmm.Transcription) error {
	ctx = context.WithoutCancel(ctx)
	if s.Biller == nil {
		return nil
	}
	units := int64(t.Price)
	reqID, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	ctx = vmm.WithExecution(ctx, vmm.Execution{ActorID: customer.String(), AgentID: rec.ID.String(), RunID: "chat:" + reqID.String(), Chat: true})
	if units > 0 {
		delta := usage.Delta{Decision: units}
		if err := s.chargeDelta(ctx, customer, rec, &bot.CostModel{}, &bot.ResourceProfile{}, 0, delta, "voice "+rec.Name); err != nil {
			return err
		}
	}
	if s.UsageLog != nil {
		if err := s.UsageLog.Record(ctx, &usage.Usage{BotID: rec.ID, Model: t.ModelID, BotName: rec.Name, ActorID: customer,
			RequestID: "chat:" + reqID.String(), Kind: usage.KindChat, Cost: units}); err != nil {
			s.L.Warn("record chat transcription usage", "bot", rec.ID.String(), "error", err)
		}
	}
	return nil
}
