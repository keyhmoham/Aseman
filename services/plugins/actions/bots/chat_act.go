package bots

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
	"gopkg.in/yaml.v3"
)

// A person's Aseman doing things for them: the answer model with tools
// (OpenAI function calling). What a tool does is the users namespace's
// (brain_tools.go): here is only the loop of asking the model, running what it
// calls and giving it what came of it, until it answers.

// brainActSteps is how many rounds of tool calls one answer may take.
const brainActSteps = 6

// BrainTool is one thing a person's Aseman can do: a function tool.
type BrainTool struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	Parameters  map[string]any `json:"parameters"`
}

// toolCall is a call the model made: its id, the tool, and its arguments (JSON).
type toolCall struct {
	ID       string `json:"id"`
	Type     string `json:"type"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"`
	} `json:"function"`
	// ExtraContent is a provider's own note on the call and must go back with it: Gemini's thinking
	// models sign each call (extra_content.google.thought_signature) and refuse the next request
	// (a 400) when the call is echoed without it.
	ExtraContent json.RawMessage `json:"extra_content,omitempty"`
}

// BrainAct is BrainAnswerStream with tools: the model may call them (run does,
// and returns what came of it, for the model) before it answers. The answer
// comes whole, through onText, once it is written. Billed like any chat answer.
//
// When the agentic engine is OpenCode or DeepSeek Harness, acting goes through
// that engine with the same MCP space tools as room turns (person-scoped
// session), not the platform LLM function-calling loop below.
func (s *Service) BrainAct(ctx context.Context, customer, botID identity.ID, brief string, turns []ChatTurn, tools []BrainTool,
	run func(name, args string) string, onText func(string)) (string, error) {
	if runtimeEngine(s.agentEngine(ctx)) {
		return s.brainActViaOpenCode(ctx, customer, botID, brief, turns, onText)
	}
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
	models, err := s.chatModels(ctx, used)
	if err != nil {
		return "", errs.Wrap(errs.CodeUnavailable, err, rec.Name+"'s model is not available")
	}
	rec = voiceBillingRecord(rec, used, voiced)
	var platform string
	_ = bridge.Invoke(ctx, s.K, "settings", "Instructions", []any{ctx}, &platform)
	messages := []map[string]any{{"role": "system", "content": brainActSystem(platform, spec, rec.Name, brief)}}
	for _, t := range turns {
		role := "user"
		if t.Role == "assistant" {
			role = "assistant"
		}
		messages = append(messages, map[string]any{"role": role, "content": t.Content})
	}
	maxTokens := spec.MaxTokens
	if maxTokens <= 0 || maxTokens > chatAnswerMaxTokens {
		maxTokens = chatAnswerMaxTokens
	}
	fns := make([]map[string]any, 0, len(tools))
	for _, t := range tools {
		fns = append(fns, map[string]any{"type": "function", "function": t})
	}
	started := time.Now()
	var in, out int64
	text := ""
	effort := chatEffort(ctx, spec)
	for step := 0; ; step++ {
		body := map[string]any{"messages": messages, "max_tokens": maxTokens}
		if effort != "" {
			body["reasoning_effort"] = effort
		}
		if step < brainActSteps && len(fns) > 0 {
			body["tools"] = fns
		}
		content, calls, i, o, callErr := callWithTools(ctx, models, body)
		in, out = in+i, out+o
		if callErr != nil {
			err = callErr
			break
		}
		if len(calls) == 0 || step >= brainActSteps {
			text = content
			break
		}
		raw, _ := json.Marshal(calls)
		var echo []any
		_ = json.Unmarshal(raw, &echo)
		said := map[string]any{"role": "assistant", "tool_calls": echo}
		if content != "" {
			said["content"] = content
		}
		messages = append(messages, said)
		for _, c := range calls {
			messages = append(messages, map[string]any{"role": "tool", "tool_call_id": c.ID, "content": run(c.Function.Name, c.Function.Arguments)})
		}
	}
	if in > 0 || out > 0 {
		if billErr := s.billChatAnswer(ctx, customer, rec, elapsedSeconds(started), in, out); billErr != nil && err == nil {
			err = billErr
		}
	}
	text = strings.TrimSpace(text)
	if text != "" && onText != nil {
		onText(text)
	}
	return text, err
}

// brainActViaOpenCode answers with tools through the runtime's CLI engine
// (OpenCode's free models, or DeepSeek Harness on the assistant's model) and a
// person-scoped MCP gateway (same space tools as room turns).
func (s *Service) brainActViaOpenCode(ctx context.Context, customer, botID identity.ID, brief string, turns []ChatTurn, onText func(string)) (string, error) {
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
	system := brainActOpenCodeSystem(platform, spec, rec.Name, brief)
	return s.answerViaEngine(ctx, customer, rec, used, system, turns, onText)
}

// brainActSystem is the brain's system prompt when it may do things (Deep Agents /
// platform LLM tool loop with propose/confirm).
func brainActSystem(platform string, spec agentChatSpec, name, brief string) string {
	return brainSystem(platform, spec, name, brief) + "\n\n" +
		"You can do things in the app for this person with your tools. Look things up (their rooms, chats, participants, " +
		"agents, apps, balance, people) whenever it helps, without asking. Anything that changes something (creating a room, " +
		"sending a message, posting in a room, inviting someone, handing work to a room's agents, recruiting or hiring an agent) " +
		"is only proposed by its tool: the person confirms it with a button or by replying yes. So say plainly what you will do " +
		"and ask them to confirm; never say it is done unless a tool said so. For work that needs a computer (research across " +
		"many sites, running code, building a page, a script or a document), propose work_on_it: it happens in their own " +
		"workspace, takes minutes, and you tell them here when it is done; say so plainly. " +
		"When they ask about a website or a link, read it with read_webpage (a few pages if one is not enough: its links " +
		"are listed) and answer from what it says; never say you have no web access. You cannot search the web in general, run code or " +
		"use a computer: for research across many sites or for building something, offer to start a room, where a team of agents can. Reminders and remembering are theirs alone and happen at once. " +
		"When it would help more than words, show rooms as cards (show_rooms) or a small chart of real numbers (show_chart) " +
		"under your answer: sparingly, never for decoration, and still say the point in a sentence."
}

// brainActOpenCodeSystem is the acting prompt when tools are OpenCode MCP space
// tools on a person-scoped gateway (same surface as a room OpenCode turn).
func brainActOpenCodeSystem(platform string, spec agentChatSpec, name, brief string) string {
	return brainSystem(platform, spec, name, brief) + "\n\n" +
		"You act as this person on their account through the Aseman MCP tools on their gateway. " +
		"You can operate spaces, rooms, threads, chats, participants, agents, apps, messages, " +
		"files, posts, explore/search, marketplace installs, follows, wallet — anything they " +
		"can do in the app (authorization is still theirs). Prefer named tools " +
		"(list_rooms, list_chats, list_team, send_message, thread_*, invite_member, post_*, " +
		"explore_spaces, account_action, …); use account_action or platform_call for anything " +
		"else. Look things up whenever it helps. Say plainly what a tool returned; never claim " +
		"you did something a tool did not confirm."
}

// callWithTools makes one chat completion that may call tools: the model is
// tried, then again, then its fallbacks, until one answers.
func callWithTools(ctx context.Context, models []vmm.ProviderConfig, body map[string]any) (string, []toolCall, int64, int64, error) {
	if len(models) == 0 {
		return "", nil, 0, 0, errs.New(errs.CodeUnavailable, "no model is available")
	}
	var last error
	for _, m := range append([]vmm.ProviderConfig{models[0]}, models...) {
		content, calls, in, out, err := callToolsOnce(ctx, m, body)
		if err == nil {
			return content, calls, in, out, nil
		}
		last = err
		if ctx.Err() != nil {
			break
		}
	}
	return "", nil, 0, 0, last
}

func callToolsOnce(ctx context.Context, provider vmm.ProviderConfig, body map[string]any) (string, []toolCall, int64, int64, error) {
	req, err := vmm.ChatRequest(ctx, provider, "/chat/completions", body)
	if err != nil {
		return "", nil, 0, 0, err
	}
	resp, err := chatAnswerHTTP.Do(req)
	if err != nil {
		return "", nil, 0, 0, errs.Wrap(errs.CodeUnavailable, err, "the model could not be reached")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return "", nil, 0, 0, errs.Wrap(errs.CodeUnavailable, err, "the model's answer was cut short")
	}
	if resp.StatusCode >= 300 {
		// What the provider said goes in the error (the node's log and the admin's AI log show it).
		return "", nil, 0, 0, errs.New(errs.CodeUnavailable, fmt.Sprintf("the model refused the request (%d): %s", resp.StatusCode, snippet(data, 400)))
	}
	var parsed struct {
		Choices []struct {
			Message struct {
				Content   any        `json:"content"`
				ToolCalls []toolCall `json:"tool_calls"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			PromptTokens     int64 `json:"prompt_tokens"`
			CompletionTokens int64 `json:"completion_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(data, &parsed); err != nil || len(parsed.Choices) == 0 {
		return "", nil, 0, 0, errs.New(errs.CodeUnavailable, "the model answered in a form that could not be read")
	}
	msg := parsed.Choices[0].Message
	return strings.TrimSpace(contentText(msg.Content)), msg.ToolCalls, parsed.Usage.PromptTokens, parsed.Usage.CompletionTokens, nil
}

// snippet is the start of a provider's reply, on one line, for an error message.
func snippet(data []byte, n int) string {
	text := strings.Join(strings.Fields(string(data)), " ")
	if len(text) > n {
		text = text[:n] + "…"
	}
	return text
}
