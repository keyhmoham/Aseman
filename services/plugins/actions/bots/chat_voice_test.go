package bots

import (
	"context"
	"testing"

	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// A call someone waits on aloud goes to the voice model first, with the agent's own model and its fallbacks behind
// it; a typed call never does; and the call is priced at the model that answers it.
func TestVoiceModelAnswersSpokenCallsWithTheOwnModelBehindIt(t *testing.T) {
	spec := agentChatSpec{Provider: "p1", Model: "big", VoiceProvider: "p2", VoiceModel: "fast", Fallbacks: []chatFallback{{Provider: "p3", Model: "backup"}}}

	typed, voiced := voiceSpec(context.Background(), spec)
	if voiced || typed.Model != "big" {
		t.Fatalf("a typed call changed model: %+v", typed)
	}
	spoken, voiced := voiceSpec(helper.WithFast(context.Background()), spec)
	if !voiced || spoken.Provider != "p2" || spoken.Model != "fast" {
		t.Fatalf("spoken call: %+v", spoken)
	}
	if len(spoken.Fallbacks) != 2 || spoken.Fallbacks[0].Model != "big" || spoken.Fallbacks[1].Model != "backup" {
		t.Fatalf("fallbacks behind the voice model: %+v", spoken.Fallbacks)
	}
	if len(spec.Fallbacks) != 1 {
		t.Fatal("the agent's own spec was changed")
	}
	none, voiced := voiceSpec(helper.WithFast(context.Background()), agentChatSpec{Provider: "p1", Model: "big"})
	if voiced || none.Model != "big" {
		t.Fatalf("no voice model set, yet changed: %+v", none)
	}

	rec := &bot.Bot{SpecYML: "name: Aseman\nprovider: p1\nmodel: big\n"}
	priced := voiceBillingRecord(rec, spoken, true)
	if p, m := bot.AgentBackbone(priced.SpecYML); p != "p2" || m != "fast" {
		t.Fatalf("priced at %s/%s", p, m)
	}
	if p, m := bot.AgentBackbone(rec.SpecYML); p != "p1" || m != "big" {
		t.Fatalf("the record itself was changed: %s/%s", p, m)
	}
	if voiceBillingRecord(rec, spoken, false) != rec {
		t.Fatal("an ordinary call was re-priced")
	}
}
