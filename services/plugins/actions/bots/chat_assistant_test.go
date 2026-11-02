package bots

import (
	"strings"
	"testing"

	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"gopkg.in/yaml.v3"
)

func TestANewAssistantStartsWithTheDefaultInstructionsAndNoModelPinned(t *testing.T) {
	var spec map[string]any
	if err := yaml.Unmarshal([]byte(chatAssistantSpec("")), &spec); err != nil {
		t.Fatal(err)
	}
	if spec["role"] != "chat" || spec["name"] != "Aseman" || spec["instructions"] != DefaultChatAssistantInstructions {
		t.Fatalf("spec: %v", spec)
	}
	if _, pinned := spec["model"]; pinned {
		t.Fatal("a new assistant pins a model: it should follow the node's default")
	}
	if !strings.Contains(DefaultChatAssistantInstructions, "no tools") || !strings.Contains(DefaultChatAssistantInstructions, "room") {
		t.Fatal("the default instructions must say what the assistant cannot do and where to go instead")
	}
}

func TestWhatAnAdminSetOnTheAssistantSurvivesARestart(t *testing.T) {
	existing := "name: Deci\nprovider: p1\nmodel: m1\ninstructions: Be brief.\nreasoning_effort: low\nfallbacks:\n  - provider: p2\n    model: m2\n"
	got := chatAssistantSpec(existing)
	for _, want := range []string{"name: Deci", "provider: p1", "model: m1", "instructions: Be brief.", "reasoning_effort: low", "model: m2"} {
		if !strings.Contains(got, want) {
			t.Fatalf("lost %q:\n%s", want, got)
		}
	}
	if bot.AgentInstructions(got) != "Be brief." || bot.AgentEffort(got) != "low" {
		t.Fatalf("instructions %q effort %q", bot.AgentInstructions(got), bot.AgentEffort(got))
	}
	// Blank instructions go back to the default rather than leaving the assistant with none.
	if got := chatAssistantSpec("name: Deci\ninstructions: \"  \"\n"); bot.AgentInstructions(got) != DefaultChatAssistantInstructions {
		t.Fatalf("blank instructions were kept: %q", bot.AgentInstructions(got))
	}
}

func TestTheAssistantIsABuiltInOfItsOwnKind(t *testing.T) {
	assistant := &bot.Bot{ImageRef: bot.BuiltinChatImage}
	lead := &bot.Bot{ImageRef: bot.BuiltinAsemanImage}
	if !assistant.IsChatAssistant() || assistant.IsBuiltinLead() || !assistant.IsBuiltin() {
		t.Fatal("assistant")
	}
	if lead.IsChatAssistant() || !lead.IsBuiltinLead() || !lead.IsBuiltin() {
		t.Fatal("lead")
	}
	if IsAseman(assistant) {
		t.Fatal("the assistant must not be treated as the room lead")
	}
}

func TestRenamingTheAssistantOrSettingItsPictureUpdatesItsPublicProfile(t *testing.T) {
	current := map[string]any{"displayName": "Aseman", "description": "The assistant in your notes and personal chats.", "avatar": "old.png"}
	got := assistantProfile(current, "Deci", map[string]any{"avatar": "new.png", "name": "Deci"})
	if got["displayName"] != "Deci" || got["avatar"] != "new.png" || got["description"] != current["description"] {
		t.Fatalf("profile: %v", got)
	}
	if current["avatar"] != "old.png" {
		t.Fatal("the stored profile was changed in place")
	}
	// A name change alone keeps the picture; a descriptor without one removes it.
	if kept := assistantProfile(current, "Deci", nil); kept["avatar"] != "old.png" {
		t.Fatalf("a rename lost the picture: %v", kept)
	}
	if cleared := assistantProfile(current, "Aseman", map[string]any{}); cleared["avatar"] != nil {
		t.Fatalf("the picture stayed: %v", cleared)
	}
}
