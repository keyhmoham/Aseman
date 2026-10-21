package spaces

import (
	"context"
	"encoding/json"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"testing"
)

type resizingBots struct {
	BotPort
	calls   int
	profile bot.ResourceProfile
}

func (b *resizingBots) Resize(_ context.Context, _ identity.ID, p bot.ResourceProfile) (*bot.Bot, error) {
	b.calls++
	b.profile = p
	data, _ := json.Marshal(p)
	return &bot.Bot{Resources: string(data)}, nil
}
func TestLegacySandboxResizesInPlaceAndPreservesCustomResources(t *testing.T) {
	for _, tc := range []struct {
		profile bot.ResourceProfile
		resize  bool
	}{{bot.ResourceProfile{CPU: 0.5, Memory: 256, Disk: 512}, true}, {bot.ResourceProfile{CPU: 1, Memory: 512, Disk: 512}, false}, {bot.ResourceProfile{CPU: 0.5, Memory: 256, Disk: 512, MaxRuntimeSec: 60}, false}} {
		b := &resizingBots{}
		s := &Service{Bots: b}
		data, _ := json.Marshal(tc.profile)
		rec := &bot.Bot{Resources: string(data)}
		got, err := s.upgradeLegacySandbox(context.Background(), rec)
		if err != nil || (b.calls == 1) != tc.resize {
			t.Fatalf("%+v calls=%d err=%v", tc, b.calls, err)
		}
		if tc.resize && (b.profile.CPU != 2 || b.profile.Memory != 2048 || b.profile.Disk != 4096) {
			t.Fatalf("%+v", b.profile)
		}
		if !tc.resize && got != rec {
			t.Fatal("custom sandbox replaced")
		}
	}
}
