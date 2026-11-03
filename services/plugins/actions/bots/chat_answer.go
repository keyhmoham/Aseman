package bots

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	usage "github.com/aseman/aseman/plugins/actions/usage/models"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
	"gopkg.in/yaml.v3"
)

// Chat answers: an agent answering a person in a chat (for now, their own
// notes) with its instructions and its model, and nothing else: no room, no
// computer, no memory, no tools. One model call, billed to the person as an
// agent's work (its time and its tokens), so it is fast.

// chatAnswerMaxTokens caps an answer when the agent sets no cap of its own.
const chatAnswerMaxTokens = 2048

// chatAnswerHTTP calls the providers; each call has its own deadline.
var chatAnswerHTTP = &http.Client{Timeout: 2 * time.Minute}

// agentChatSpec is what a chat answer uses of an agent's spec.
type agentChatSpec struct {
	Name         string `yaml:"name"`
	Description  string `yaml:"description"`
	Provider     string `yaml:"provider"`
	Model        string `yaml:"model"`
	Instructions string `yaml:"instructions"`
	MaxTokens    int    `yaml:"max_tokens"`
	// Fallbacks are asked, in order, when the model fails before it begins to answer.
	Fallbacks       []chatFallback `yaml:"fallbacks"`
	ReasoningEffort string         `yaml:"reasoning_effort"`
	// VoiceProvider and VoiceModel answer a call someone is waiting on aloud (a live voice chat), in place of the
	// agent's own model: one that is quicker to its first words. The agent's own model then stands behind it.
	VoiceProvider string `yaml:"voice_provider"`
	VoiceModel    string `yaml:"voice_model"`
	// VoiceReasoningEffort is used instead of ReasoningEffort when someone talks to the agent aloud.
	VoiceReasoningEffort string `yaml:"voice_reasoning_effort"`
}

// chatAnswerSystem is the agent's system prompt in a chat: the node's own
// instructions for every agent, its persona, and where it is.
func chatAnswerSystem(platform string, spec agentChatSpec, name string) string {
	var b strings.Builder
	if strings.TrimSpace(platform) != "" {
		b.WriteString("Platform instructions:\n" + strings.TrimSpace(platform) + "\n\n")
	}
	fmt.Fprintf(&b, "You are %s.", name)
	if d := strings.TrimSpace(spec.Description); d != "" {
		b.WriteString(" " + d)
	}
	if in := strings.TrimSpace(spec.Instructions); in != "" {
		b.WriteString("\n\n" + in)
	}
	b.WriteString("\n\nYou are answering a person in a chat. Answer in this one message, concisely, in Markdown. " +
		"You have no tools, files or computer here, and nothing from their rooms: if the request needs those, say so and suggest doing it in a room.")
	return b.String()
}

// ChatTurn is one message of the conversation an answer is given to: Role is "user" or "assistant".
type ChatTurn struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// chatStreamHTTP carries streamed answers: no overall timeout, because the caller's context
// and the stream limits bound them.
var chatStreamHTTP = &http.Client{}

// chatModels are the models a chat answer may be asked of, in order: the agent's own,
// then its fallbacks that the node can still resolve.
func (s *Service) chatModels(ctx context.Context, spec agentChatSpec) ([]vmm.ProviderConfig, error) {
	var primary vmm.ProviderConfig
	if err := bridge.Invoke(ctx, s.K, "llm", "ResolveChat", []any{ctx, spec.Provider, spec.Model}, &primary); err != nil {
		return nil, errs.Wrap(errs.CodeUnavailable, err, "the model is not available")
	}
	models := []vmm.ProviderConfig{primary}
	for _, ref := range spec.Fallbacks {
		var fb vmm.ProviderConfig
		if err := bridge.Invoke(ctx, s.K, "llm", "ResolveChat", []any{ctx, ref.Provider, ref.Model}, &fb); err == nil {
			models = append(models, fb)
		}
	}
	return models, nil
}

// ChatAnswerStream has an agent answer a conversation, streaming: onText gets the whole answer so
// far each time it grows. The agent's model is tried, then asked again, then its fallbacks, but only
// until words appear; a failure after that ends the answer early with what was written (returned with
// the error). Billed to customer for the tokens used (and, for an agent other than the chat
// assistant, its time), including an answer that did not arrive whole.
func (s *Service) ChatAnswerStream(ctx context.Context, customer, botID identity.ID, turns []ChatTurn, onText func(string)) (string, error) {
	return s.answerStream(ctx, customer, botID, turns, chatAnswerSystem, false, onText)
}


// answerStream is ChatAnswerStream with the system prompt system makes. A
// personal answer (the person's own Aseman) runs on the agent runtime as the
// person; any other agent's chat answer is one streamed model call.
func (s *Service) answerStream(ctx context.Context, customer, botID identity.ID, turns []ChatTurn, system func(platform string, spec agentChatSpec, name string) string, personal bool, onText func(string)) (string, error) {
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
	prompt := system(platform, spec, rec.Name)
	// Personal Aseman (notes / Talk) runs on the agent runtime, on the
	// assistant's platform model, with the person's own memory and tools.
	if personal {
		return s.answerViaEngine(ctx, customer, rec, used, prompt, turns, onText)
	}
	models, err := s.chatModels(ctx, used)
	if err != nil {
		return "", errs.Wrap(errs.CodeUnavailable, err, rec.Name+"'s model is not available")
	}
	messages := []map[string]any{{"role": "system", "content": prompt}}
	sent := len(prompt)
	for _, t := range turns {
		role := "user"
		if t.Role == "assistant" {
			role = "assistant"
		}
		messages = append(messages, map[string]any{"role": role, "content": t.Content})
		sent += len(t.Content)
	}
	maxTokens := spec.MaxTokens
	if maxTokens <= 0 || maxTokens > chatAnswerMaxTokens {
		maxTokens = chatAnswerMaxTokens
	}
	body := map[string]any{"messages": messages, "max_tokens": maxTokens}
	if effort := chatEffort(ctx, spec); effort != "" {
		body["reasoning_effort"] = effort
	}
	started := time.Now()
	res, callErr := streamChat(ctx, chatStreamHTTP, models, body, defaultChatLimits, onText)
	in, out := res.In, res.Out
	// Nothing was asked of any model that worked: nothing to bill.
	if res.Text == "" && in == 0 && out == 0 && callErr != nil {
		return "", callErr
	}
	if in == 0 {
		in = int64(sent) / 4
	}
	if out == 0 {
		out = int64(len(res.Text)) / 4
	}
	if err := s.billChatAnswer(ctx, customer, rec, elapsedSeconds(started), in, out); err != nil && callErr == nil {
		callErr = err
	}
	return strings.TrimSpace(res.Text), callErr
}

// harnessChatTimeout bounds one personal answer on the agent runtime. Cold
// starts (runtime schedule + first model call) need longer than a chat answer.
const harnessChatTimeout = 8 * time.Minute



// answerViaEngine answers a personal chat on the agent runtime (DeepSeek
// Harness), as the person, with their access across the app. It runs on the
// assistant's model (spec): its tokens are billed like any chat answer.
func (s *Service) answerViaEngine(ctx context.Context, customer identity.ID, rec *bot.Bot, spec agentChatSpec, system string, turns []ChatTurn, onText func(string)) (string, error) {
	vm := s.K.VMMFor(vmm.TypeHarness)
	chatter, ok := vm.(vmm.PersonalChatter)
	if !ok || vm == nil {
		return "", errs.New(errs.CodeUnavailable, "the agent runtime cannot answer personal chats on this node")
	}
	msgs := make([]vmm.ChatMessage, 0, len(turns))
	for _, t := range turns {
		role := "user"
		if t.Role == "assistant" {
			role = "assistant"
		}
		msgs = append(msgs, vmm.ChatMessage{Role: role, Content: t.Content})
	}
	started := time.Now()
	callCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), harnessChatTimeout)
	defer cancel()
	var used vmm.ChatUsage
	reply, err := chatter.PersonalChat(callCtx, vmm.PersonalChat{
		System: system, Messages: msgs, ThreadID: "chat:" + customer.String(),
		PersonID: customer.String(), WithTools: true,
		Provider: spec.Provider, Model: spec.Model, Usage: &used,
	})
	reply = strings.TrimSpace(reply)
	if reply != "" && onText != nil {
		onText(reply)
	}
	if reply == "" && err != nil && used.TokensIn == 0 && used.TokensOut == 0 {
		return "", err
	}
	// The harness's model calls were metered on the person's session.
	if billErr := s.billChatAnswer(ctx, customer, rec, elapsedSeconds(started), used.TokensIn, used.TokensOut); billErr != nil && err == nil {
		err = billErr
	}
	return reply, err
}

// ChatAnswer has an agent answer prompt for customer in a chat, and bills
// them for it. It returns the answer.
func (s *Service) ChatAnswer(ctx context.Context, customer, botID identity.ID, prompt string) (string, error) {
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
	var platform string
	_ = bridge.Invoke(ctx, s.K, "settings", "Instructions", []any{ctx}, &platform)
	sys := chatAnswerSystem(platform, spec, rec.Name)
	var provider vmm.ProviderConfig
	if err := bridge.Invoke(ctx, s.K, "llm", "ResolveChat", []any{ctx, spec.Provider, spec.Model}, &provider); err != nil {
		return "", errs.Wrap(errs.CodeUnavailable, err, rec.Name+"'s model is not available")
	}
	maxTokens := spec.MaxTokens
	if maxTokens <= 0 || maxTokens > chatAnswerMaxTokens {
		maxTokens = chatAnswerMaxTokens
	}
	body := map[string]any{
		"messages": []map[string]any{
			{"role": "system", "content": sys},
			{"role": "user", "content": prompt},
		},
		"max_tokens": maxTokens,
	}
	started := time.Now()
	reply, in, out, callErr := callChat(ctx, provider, body)
	// What was used is paid for even when the answer did not arrive whole.
	if in == 0 && out == 0 && callErr != nil && ctx.Err() == nil {
		return "", callErr // refused before any work: nothing to bill
	}
	if in == 0 {
		in = int64(len(sys)+len(prompt)) / 4
	}
	if err := s.billChatAnswer(ctx, customer, rec, elapsedSeconds(started), in, out); err != nil && callErr == nil {
		callErr = err
	}
	return reply, callErr
}

// billChatAnswer charges a chat answer as an agent's work: its time and its
// model's tokens, paid to the agent's owner, the node and the key's owner.
func (s *Service) billChatAnswer(ctx context.Context, customer identity.ID, rec *bot.Bot, seconds, in, out int64) error {
	ctx = context.WithoutCancel(ctx)
	if s.Biller == nil {
		return nil
	}
	// The charge is the person's own usage of no room ("Chats" on Usage and
	// in the admin's views), under one request id tying it to its tokens.
	reqID, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	ctx = vmm.WithExecution(ctx, vmm.Execution{ActorID: customer.String(), AgentID: rec.ID.String(), RunID: "chat:" + reqID.String(), Chat: true})
	cost := s.costFor(ctx, rec)
	if rec.IsChatAssistant() {
		// The assistant is paid for in tokens only: a few seconds of a chat reply is not a unit of work to price.
		cost = &bot.CostModel{}
	}
	delta := usage.Delta{TokensIn: in, TokensOut: out}
	if err := s.chargeDelta(ctx, customer, rec, cost, &bot.ResourceProfile{}, seconds, delta, "chat answer "+rec.Name); err != nil {
		return err
	}
	if s.UsageLog != nil {
		provider, model := AgentBackbone(rec.SpecYML)
		delta.Cost = s.llmChargeAmount(ctx, rec, cost, delta)
		if err := s.UsageLog.Record(ctx, &usage.Usage{BotID: rec.ID, Provider: provider, Model: model, BotName: rec.Name, ActorID: customer,
			RequestID: "chat:" + reqID.String(), Kind: usage.KindChat, TokensIn: in, TokensOut: out, Cost: delta.Cost}); err != nil {
			s.L.Warn("record chat answer usage", "bot", rec.ID.String(), "error", err)
		}
	}
	return nil
}

// elapsedSeconds is how long something has run, in whole seconds (at least one).
func elapsedSeconds(started time.Time) int64 {
	return max(int64(time.Since(started).Seconds()+0.999), 1)
}

// callChat makes one OpenAI-compatible chat completion and returns the text
// and the tokens the provider reports.
func callChat(ctx context.Context, provider vmm.ProviderConfig, body map[string]any) (string, int64, int64, error) {
	req, err := vmm.ChatRequest(ctx, provider, "/chat/completions", body)
	if err != nil {
		return "", 0, 0, err
	}
	resp, err := chatAnswerHTTP.Do(req)
	if err != nil {
		return "", 0, 0, errs.Wrap(errs.CodeUnavailable, err, "the model could not be reached")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return "", 0, 0, errs.Wrap(errs.CodeUnavailable, err, "the model's answer was cut short")
	}
	if resp.StatusCode >= 300 {
		return "", 0, 0, errs.New(errs.CodeUnavailable, fmt.Sprintf("the model refused the request (%d)", resp.StatusCode))
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content any `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			PromptTokens     int64 `json:"prompt_tokens"`
			CompletionTokens int64 `json:"completion_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return "", 0, 0, errs.New(errs.CodeUnavailable, "the model answered in a form that could not be read")
	}
	text := ""
	if len(out.Choices) > 0 {
		text = contentText(out.Choices[0].Message.Content)
	}
	return strings.TrimSpace(text), out.Usage.PromptTokens, out.Usage.CompletionTokens, nil
}

// contentText is a message's text: a string, or the text parts of a list.
func contentText(c any) string {
	switch v := c.(type) {
	case string:
		return v
	case []any:
		var b strings.Builder
		for _, p := range v {
			if m, ok := p.(map[string]any); ok {
				if t, ok := m["text"].(string); ok {
					b.WriteString(t)
				}
			}
		}
		return b.String()
	}
	return ""
}

// chatEffort is the reasoning effort for one call ("" = send none). Someone talking aloud (helper.Fast) gets the
// voice effort the admin set; without one, the agent's own effort lowered to "low": only an effort the admin already
// set is touched, so a model that takes no such setting is never sent one.
func chatEffort(ctx context.Context, spec agentChatSpec) string {
	fast := helper.Fast(ctx)
	if fast {
		if v, ok := bot.NormalizeEffort(spec.VoiceReasoningEffort); ok && v != "" {
			return v
		}
	}
	effort, ok := bot.NormalizeEffort(spec.ReasoningEffort)
	if !ok || effort == "" {
		return ""
	}
	if fast {
		return "low"
	}
	return effort
}
