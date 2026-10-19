package bots

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/bridge"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/bots/models/bot"
	usage "github.com/tradera/tradera/plugins/actions/usage/models"
	vmm "github.com/tradera/tradera/plugins/adapters/vmm/ports"
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
	var provider vmm.ProviderConfig
	if err := bridge.Invoke(ctx, s.K, "llm", "ResolveChat", []any{ctx, spec.Provider, spec.Model}, &provider); err != nil {
		return "", errs.Wrap(errs.CodeUnavailable, err, rec.Name+"'s model is not available")
	}
	var platform string
	_ = bridge.Invoke(ctx, s.K, "settings", "Instructions", []any{ctx}, &platform)
	maxTokens := spec.MaxTokens
	if maxTokens <= 0 || maxTokens > chatAnswerMaxTokens {
		maxTokens = chatAnswerMaxTokens
	}
	body := map[string]any{
		"messages": []map[string]any{
			{"role": "system", "content": chatAnswerSystem(platform, spec, rec.Name)},
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
		in = int64(len(chatAnswerSystem(platform, spec, rec.Name))+len(prompt)) / 4
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
	isVertex := provider.Kind == "vertex" || strings.Contains(provider.BaseURL, "aiplatform.googleapis.com")
	google := isVertex || provider.Kind == "gemini" || strings.Contains(provider.BaseURL, "googleapis.com")
	model := provider.Model
	if isVertex && !strings.Contains(model, "/") {
		model = "google/" + model
	}
	body["model"] = model
	payload, err := json.Marshal(body)
	if err != nil {
		return "", 0, 0, err
	}
	base := provider.BaseURL
	if isVertex && strings.Contains(base, "{location}") {
		base = strings.ReplaceAll(base, "{location}", "us-central1")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(base, "/")+"/chat/completions", bytes.NewReader(payload))
	if err != nil {
		return "", 0, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	if provider.APIKey != "" {
		if google && !strings.HasPrefix(provider.APIKey, "ya29.") {
			req.Header.Set("X-Goog-Api-Key", provider.APIKey)
		} else {
			req.Header.Set("Authorization", "Bearer "+provider.APIKey)
		}
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
