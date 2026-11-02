package bots

import (
	"context"

	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"gopkg.in/yaml.v3"
)

// chatFallback is a model asked when the one before it fails.
type chatFallback struct {
	Provider string `yaml:"provider"`
	Model    string `yaml:"model"`
}

// voiceSpec is the agent as a call someone waits on aloud (helper.Fast) should use it: with a voice model set, that
// model first and the agent's own model (and its fallbacks) behind it. Anything else gets the spec as it is.
func voiceSpec(ctx context.Context, spec agentChatSpec) (agentChatSpec, bool) {
	if !helper.Fast(ctx) || spec.VoiceModel == "" {
		return spec, false
	}
	used := spec
	used.Provider, used.Model = spec.VoiceProvider, spec.VoiceModel
	used.Fallbacks = append([]chatFallback{{Provider: spec.Provider, Model: spec.Model}}, spec.Fallbacks...)
	return used, true
}

// voiceBillingRecord is the agent with the voice model as its backbone, so the call is priced at the model that
// answered it (the agent's own model is billed for in the ordinary way).
func voiceBillingRecord(rec *bot.Bot, used agentChatSpec, voiced bool) *bot.Bot {
	if !voiced {
		return rec
	}
	var spec map[string]any
	if yaml.Unmarshal([]byte(rec.SpecYML), &spec) != nil || spec == nil {
		return rec
	}
	spec["provider"], spec["model"] = used.Provider, used.Model
	out, err := yaml.Marshal(spec)
	if err != nil {
		return rec
	}
	priced := *rec
	priced.SpecYML = string(out)
	return &priced
}
