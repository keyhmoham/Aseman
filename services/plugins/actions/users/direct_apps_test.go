package users

import (
	"testing"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
)

func TestPeopleDoNotMessageAppsDirectly(t *testing.T) {
	s, ctx := followHarness(t)
	alice := mustID(t, "00000000000000010000000000000001")
	add := func(id, account string, kind bot.Kind, vm bot.VMType, name string) {
		t.Helper()
		b := &bot.Bot{Entity: entity.Entity{ID: mustID(t, id)}, AccountID: mustID(t, account), Kind: kind, VMType: vm, Name: name}
		if err := s.R.CreateID(ctx, "bots", b.ID, b); err != nil {
			t.Fatal(err)
		}
	}
	add("00000000000000010000000000000070", "00000000000000010000000000000071", bot.KindTool, bot.VMTypeMCP, "Google")
	add("00000000000000010000000000000080", "00000000000000010000000000000081", bot.KindAgent, bot.VMTypeHarness, "Ada")
	app, agent := mustID(t, "00000000000000010000000000000071"), mustID(t, "00000000000000010000000000000081")
	if err := s.directAllowed(ctx, alice, app); err == nil {
		t.Fatal("a person does not message an app")
	}
	if err := s.directAllowed(ctx, agent, app); err != nil {
		t.Fatalf("an agent does: %v", err)
	}
	if err := s.directAllowed(ctx, alice, agent); err != nil {
		t.Fatalf("a person messages an agent: %v", err)
	}
	if _, ok := s.agentAccount(ctx, app); !ok {
		t.Fatal("an app answers the direct messages it may get")
	}
}
