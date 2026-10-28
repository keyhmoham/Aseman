package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/finance/models/wallet"
	usage "github.com/aseman/aseman/plugins/actions/usage/models"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Completion is one short model call the node makes for a person, outside
// any agent's turn: sorting their mail, writing their brief's summary,
// drafting a skill from a demonstration.
type Completion struct {
	Payer   identity.ID `json:"payer"`
	SpaceID identity.ID `json:"space_id"`
	// Purpose names the call in the person's usage ("mail triage").
	Purpose   string `json:"purpose"`
	System    string `json:"system"`
	User      string `json:"user"`
	MaxTokens int    `json:"max_tokens,omitempty"`
	// JSON asks for a JSON object back.
	JSON bool `json:"json,omitempty"`
}

// CompletionResult is the model's answer and what it cost.
type CompletionResult struct {
	Text      string `json:"text"`
	Model     string `json:"model"`
	TokensIn  int64  `json:"tokens_in"`
	TokensOut int64  `json:"tokens_out"`
	Cost      int64  `json:"cost"`
}

var completeClient = &http.Client{Timeout: 90 * time.Second}

// Complete runs one call on the node's default chat model and bills it to the
// payer like their agents' model use: at the model's prices, paid to the
// owner of the provider's key, in the project's spend.
func (s *Service) Complete(ctx context.Context, c Completion) (CompletionResult, error) {
	if c.Payer.IsZero() {
		return CompletionResult{}, errs.InvalidArgument("a completion needs someone to pay for it")
	}
	provider, err := s.ResolveChat(ctx, "", "")
	if err != nil {
		return CompletionResult{}, err
	}
	price, err := s.PriceFor(ctx, "", provider.Model)
	if err != nil {
		return CompletionResult{}, err
	}
	if c.MaxTokens <= 0 {
		c.MaxTokens = 800
	}
	body := map[string]any{"model": provider.Model, "max_tokens": c.MaxTokens, "temperature": 0,
		"messages": []map[string]string{{"role": "system", "content": c.System}, {"role": "user", "content": c.User}}}
	if c.JSON {
		body["response_format"] = map[string]string{"type": "json_object"}
	}
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(provider.BaseURL, "/")+"/chat/completions", bytes.NewReader(raw))
	if err != nil {
		return CompletionResult{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	google := provider.Kind == "gemini" || provider.Kind == "vertex" || strings.Contains(provider.BaseURL, "googleapis.com")
	if google && !strings.HasPrefix(provider.APIKey, "ya29.") {
		req.Header.Set("X-Goog-Api-Key", provider.APIKey)
	} else if provider.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+provider.APIKey)
	}
	resp, err := completeClient.Do(req)
	if err != nil {
		return CompletionResult{}, errs.Wrap(errs.CodeUnavailable, err, "model")
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode >= 300 {
		return CompletionResult{}, errs.New(errs.CodeUnavailable, "model answered "+resp.Status+": "+clipText(string(data), 300))
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			Prompt     int64 `json:"prompt_tokens"`
			Completion int64 `json:"completion_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(data, &out); err != nil || len(out.Choices) == 0 {
		return CompletionResult{}, errs.New(errs.CodeUnavailable, "the model's answer could not be read")
	}
	res := CompletionResult{Text: strings.TrimSpace(out.Choices[0].Message.Content), Model: provider.Model,
		TokensIn: out.Usage.Prompt, TokensOut: out.Usage.Completion}
	res.Cost = price.TokenCost(res.TokensIn, res.TokensOut)
	k, ok := s.K.(api.Kernel)
	if !ok {
		return res, nil
	}
	if res.Cost > 0 && !price.Payee.IsZero() {
		billCtx := vmm.WithExecution(context.WithoutCancel(ctx), vmm.Execution{SpaceID: c.SpaceID.String(), ActorID: c.Payer.String()})
		desc := "model: " + firstWord(c.Purpose, "completion")
		lines := []wallet.ChargeLine{{Amount: res.Cost, Payees: []identity.ID{price.Payee}, Type: wallet.EntryPayLLM, Category: wallet.CategoryLLM, Desc: desc}}
		if err := bridge.Invoke(billCtx, k, "finance", "ChargeLines", []any{billCtx, c.Payer, desc, lines}); err != nil {
			return res, err
		}
	}
	if !c.SpaceID.IsZero() {
		_ = bridge.Invoke(ctx, k, "usage", "Record", []any{ctx, &usage.Usage{SpaceID: c.SpaceID, ActorID: c.Payer, BotName: c.Purpose,
			Provider: provider.Kind, Model: provider.Model, Kind: "node", TokensIn: res.TokensIn, TokensOut: res.TokensOut, Cost: res.Cost}})
	}
	return res, nil
}

func firstWord(v, def string) string {
	if strings.TrimSpace(v) == "" {
		return def
	}
	return strings.TrimSpace(v)
}

func clipText(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
