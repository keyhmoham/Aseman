package bots

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"gopkg.in/yaml.v3"
)

// A person's Aseman doing things for them: it acts on the agent runtime
// (DeepSeek Harness) as the person, with the runtime's own tools.

// BrainTool is one thing a person's Aseman can do: a function tool.
type BrainTool struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Parameters  map[string]any `json:"parameters"`
}

// BrainAct is BrainAnswerStream with the person's tools: their Aseman acts in
// the app for them on the agent runtime (DeepSeek Harness), as the person and
// with their access across the app (the agents' policy applies), then
// answers. The answer comes whole, through onText. Billed like any chat
// answer. tools and run are what older callers offer; the runtime brings its
// own tools now.
func (s *Service) BrainAct(ctx context.Context, customer, botID identity.ID, brief string, turns []ChatTurn, tools []BrainTool,
	run func(name, args string) string, onText func(string)) (string, error) {
	return s.brainActViaHarness(ctx, customer, botID, brief, turns, onText)
}

// brainActViaHarness answers with tools on the agent runtime, on the
// assistant's model, through a person-scoped gateway session.
func (s *Service) brainActViaHarness(ctx context.Context, customer, botID identity.ID, brief string, turns []ChatTurn, onText func(string)) (string, error) {
	rec, err := s.GetBot(ctx, botID)
	if err != nil {
		return "", err
	}
	if rec.Kind != bot.KindAgent {
		return "", errs.InvalidArgument(rec.Name + " is not an agent")
	}
	if err := s.EnsureFunds(ctx, customer, botID); err != nil {
		return "", err
	}
	var spec agentChatSpec
	_ = yaml.Unmarshal([]byte(rec.SpecYML), &spec)
	used, voiced := voiceSpec(ctx, spec)
	rec = voiceBillingRecord(rec, used, voiced)
	var platform string
	_ = bridge.Invoke(ctx, s.K, "settings", "Instructions", []any{ctx}, &platform)
	system := brainActHarnessSystem(platform, spec, rec.Name, brief)
	return s.answerViaEngine(ctx, customer, rec, used, system, turns, onText)
}

// brainActHarnessSystem is the acting prompt of a person's Aseman on the agent
// runtime: it acts as the person, with their access across the app.
func brainActHarnessSystem(platform string, spec agentChatSpec, name, brief string) string {
	return brainSystem(platform, spec, name, brief) + "\n\n" +
		"You act as this person, on their account and with their access across the whole app: spaces, rooms, " +
		"threads, chats and participants, agents, apps and plugins, messages, files and media, posts, the " +
		"marketplace, themes, routines, follows and their wallet. Find what the platform can do with " +
		"aseman_api_search and do it with aseman_api_call (authorization is still theirs). Look things up " +
		"whenever it helps. Before anything that cannot be undone, or that speaks for them to other people, " +
		"say what you will do and ask them to confirm (ask_user). Say plainly what a tool returned; never " +
		"claim you did something a tool did not confirm."
}
