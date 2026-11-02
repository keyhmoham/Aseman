package bots

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	usage "github.com/aseman/aseman/plugins/actions/usage/models"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// ChatSpeak has the node's speech model say text aloud for customer (a live voice chat with their Aseman), and bills
// them for it at that model's prices as their use of no room, like the answer it speaks.
func (s *Service) ChatSpeak(ctx context.Context, customer, botID identity.ID, text string) (*vmm.Speech, error) {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return nil, err
	}
	if err := s.EnsureFunds(ctx, customer, botID); err != nil {
		return nil, err
	}
	var speech *vmm.Speech
	if err := bridge.Invoke(ctx, s.K, "llm", "Speak", []any{ctx, text}, &speech); err != nil {
		return nil, err
	}
	if speech == nil || len(speech.Audio) == 0 {
		return nil, errs.New(errs.CodeUnavailable, "the speech model made no audio")
	}
	if err := s.billChatSpeech(ctx, customer, rec, speech); err != nil {
		s.L.Warn("chat speech not billed", "bot", rec.ID.String(), "error", err)
	}
	return speech, nil
}

// billChatSpeech charges speech at the speech model's own prices (already in speech.Price).
func (s *Service) billChatSpeech(ctx context.Context, customer identity.ID, rec *bot.Bot, speech *vmm.Speech) error {
	ctx = context.WithoutCancel(ctx)
	if s.Biller == nil {
		return nil
	}
	units := int64(speech.Price)
	reqID, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	ctx = vmm.WithExecution(ctx, vmm.Execution{ActorID: customer.String(), AgentID: rec.ID.String(), RunID: "chat:" + reqID.String(), Chat: true})
	if units > 0 {
		// Priced extras ride on the decision field of a delta (what the node's own models charge); the usage row below says what it was.
		delta := usage.Delta{Decision: units}
		if err := s.chargeDelta(ctx, customer, rec, &bot.CostModel{}, &bot.ResourceProfile{}, 0, delta, "voice "+rec.Name); err != nil {
			return err
		}
	}
	if s.UsageLog != nil {
		if err := s.UsageLog.Record(ctx, &usage.Usage{BotID: rec.ID, Model: speech.ModelID, BotName: rec.Name, ActorID: customer,
			RequestID: "chat:" + reqID.String(), Kind: usage.KindChat, TokensIn: speech.TokensIn, TokensOut: speech.TokensOut, Cost: units}); err != nil {
			s.L.Warn("record chat speech usage", "bot", rec.ID.String(), "error", err)
		}
	}
	return nil
}
