package tools

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/bots/models/bot"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// An app is a bot like any other: people mention it in a room, message it
// directly, give it to a routine, and agents ask it, all in plain words. A
// backend with a function named "ask" takes the words itself. For any other
// (the Google app, a Composio or Arcade server, most MCP servers) the node's
// model turns the words into one call of its functions, as the person, and
// what that call returns is the answer. When an agent is behind the words,
// the call it turned into is decided by the gate like any agent action, so
// "send it to Marco" still asks before gmail_send.

// wordsCompletion and wordsCompletionResult mirror llm.Completion: this
// namespace owns its view of the llm namespace's contract.
type wordsCompletion struct {
	Payer     identity.ID `json:"payer"`
	SpaceID   identity.ID `json:"space_id"`
	Purpose   string      `json:"purpose"`
	System    string      `json:"system"`
	User      string      `json:"user"`
	MaxTokens int         `json:"max_tokens,omitempty"`
	JSON      bool        `json:"json,omitempty"`
}

type wordsCompletionResult struct {
	Text string `json:"text"`
}

// WordsModel picks a function for a request (llm.Complete when nil).
type WordsModel func(ctx context.Context, c wordsCompletion) (string, error)

func (s *Service) complete(ctx context.Context, c wordsCompletion) (string, error) {
	if s.Words != nil {
		return s.Words(ctx, c)
	}
	var out wordsCompletionResult
	err := bridge.Invoke(ctx, s.K, "llm", "Complete", []any{ctx, c}, &out)
	return out.Text, err
}

const wordsSystem = `You turn a person's request to an app into one call of the app's functions.
Answer with a JSON object only:
{"function": "<one of the functions>", "arguments": {...}} matching that function's input schema, or
{"reply": "<one or two sentences>"} when no function fits or something the call needs is missing (say what).
Never invent ids or addresses the request does not give; never call more than one function.`

// answerInWords answers a plain-words request to an app.
func (s *Service) answerInWords(ctx context.Context, ep *endpoint, rec *bot.Bot, actor identity.ID, spaceID, words string) (string, error) {
	listed, err := s.rpc(ctx, ep, "tools/list", map[string]any{})
	if err != nil {
		return "", err
	}
	functions := commandDefs(listed)
	for _, f := range functions {
		if f["name"] == "ask" {
			return s.callText(ctx, ep, "ask", map[string]any{"request": words})
		}
	}
	if len(functions) == 0 {
		return "", errs.New(errs.CodeUnavailable, rec.Name+" offers no functions")
	}
	var catalog strings.Builder
	names := make([]string, 0, len(functions))
	for _, f := range functions {
		schema, _ := json.Marshal(f["schema"])
		fmt.Fprintf(&catalog, "- %v: %v\n  input: %s\n", f["name"], f["description"], schema)
		names = append(names, fmt.Sprint(f["name"]))
	}
	space, _ := identity.Parse(spaceID)
	text, err := s.complete(ctx, wordsCompletion{Payer: actor, SpaceID: space, Purpose: "asking " + rec.Name, System: wordsSystem, JSON: true, MaxTokens: 800,
		User: "App: " + rec.Name + "\nFunctions:\n" + catalog.String() + "\nRequest:\n" + words})
	if err != nil {
		return "", errs.New(errs.CodeUnavailable, rec.Name+" takes its functions by name ("+strings.Join(names, ", ")+"): send {\"function\": …, \"payload\": {…}}; the node's model is unavailable to read plain words ("+err.Error()+")")
	}
	var pick struct {
		Function  string         `json:"function"`
		Arguments map[string]any `json:"arguments"`
		Reply     string         `json:"reply"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(text)), &pick); err != nil {
		return "", errs.New(errs.CodeUnavailable, "could not read the request for "+rec.Name)
	}
	if pick.Function == "" {
		if pick.Reply == "" {
			pick.Reply = "I could not tell which of " + rec.Name + "'s functions you mean: " + strings.Join(names, ", ") + "."
		}
		return pick.Reply, nil
	}
	known := false
	for _, n := range names {
		known = known || n == pick.Function
	}
	if !known {
		return "", errs.InvalidArgument(rec.Name + " has no function " + pick.Function)
	}
	if pick.Arguments == nil {
		pick.Arguments = map[string]any{}
	}
	args, err := s.gateWords(ctx, rec, spaceID, pick.Function, pick.Arguments)
	if err != nil {
		return "", err
	}
	return s.callText(ctx, ep, pick.Function, args)
}

// gateWords decides the call plain words turned into, when an agent is
// behind them (a person asking an app themselves acts for themselves). It
// returns the arguments to call with (secrets put in).
func (s *Service) gateWords(ctx context.Context, rec *bot.Bot, spaceID, function string, args map[string]any) (map[string]any, error) {
	exec := vmm.ExecutionFrom(ctx)
	// A person's own ask names the app itself as the execution's agent.
	if (exec.AgentID == "" || exec.AgentID == rec.ID.String()) && exec.RunID == "" {
		return args, nil
	}
	raw, _ := json.Marshal(args)
	req := gate.Request{Kind: gate.KindApp, Tool: strings.ToLower(rec.Name) + "/" + function, App: strings.ToLower(rec.Name), Function: function,
		Args: raw, SpaceID: spaceID, RoomID: exec.RoomID, AgentID: exec.AgentID}
	res, err := gate.Check(ctx, s.K, req)
	if err != nil {
		return nil, err
	}
	if len(res.Args) > 0 && string(res.Args) != string(raw) {
		var substituted map[string]any
		if json.Unmarshal(res.Args, &substituted) == nil {
			return substituted, nil
		}
	}
	return args, nil
}

// callText calls one function and answers with what it says.
func (s *Service) callText(ctx context.Context, ep *endpoint, function string, args map[string]any) (string, error) {
	result, err := s.rpc(ctx, ep, "tools/call", map[string]any{"name": function, "arguments": args})
	if err != nil {
		return "", err
	}
	var parts []string
	content, _ := result["content"].([]any)
	for _, c := range content {
		item, _ := c.(map[string]any)
		if t, _ := item["text"].(string); t != "" {
			parts = append(parts, t)
		}
	}
	text := strings.Join(parts, "\n")
	if failed, _ := result["isError"].(bool); failed {
		return "", errs.New(errs.CodeUnavailable, function+": "+text)
	}
	if text == "" {
		raw, _ := json.Marshal(result)
		return string(raw), nil
	}
	return text, nil
}
