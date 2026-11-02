package vmm

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strings"
)

// ProviderConfig is a resolved LLM provider endpoint: the OpenAI-compatible
// base URL, API key and the model to call.
type ProviderConfig struct {
	Kind    string
	BaseURL string
	APIKey  string
	Model   string
	// ContextWindow is the model's input window in tokens (0 = unknown).
	ContextWindow int
	// ImageModel / ImagePrice are set when resolving an image provider.
	ImageModel string
	ImagePrice float64
	// InputPrice / OutputPrice (credits per 1M tokens) are set when resolving
	// the decision model, whose usage is priced apart from the agent's model.
	InputPrice  float64
	OutputPrice float64
	// AutoApprove is the decision model's permission to approve low-risk
	// tool calls that otherwise wait on a person.
	AutoApprove bool
	// OwnerID is the account that owns the provider's API key: what the model
	// costs is paid to it (set when resolving the memory models).
	OwnerID string
}

// DecisionURL is the decision API of a provider: its evaluate endpoint next
// to its OpenAI-compatible base (Vercel AI Gateway: …/v1/evaluate).
func DecisionURL(base string) string {
	base = strings.TrimRight(base, "/")
	if strings.HasSuffix(base, "/evaluate") {
		return base
	}
	return base + "/evaluate"
}

// ChatRequest is a POST of body to one of a provider's OpenAI-compatible endpoints
// (path: "/chat/completions") for its model, with the provider's key. It knows what the
// providers differ in: Vertex names its models "google/<model>", fills {location} in
// its URL, and takes Google API keys in a header of their own.
func ChatRequest(ctx context.Context, provider ProviderConfig, path string, body map[string]any) (*http.Request, error) {
	isVertex := provider.Kind == "vertex" || strings.Contains(provider.BaseURL, "aiplatform.googleapis.com")
	google := isVertex || provider.Kind == "gemini" || strings.Contains(provider.BaseURL, "googleapis.com")
	model := provider.Model
	if isVertex && !strings.Contains(model, "/") {
		model = "google/" + model
	}
	sent := make(map[string]any, len(body)+1)
	for k, v := range body {
		sent[k] = v
	}
	sent["model"] = model
	payload, err := json.Marshal(sent)
	if err != nil {
		return nil, err
	}
	base := provider.BaseURL
	if isVertex && strings.Contains(base, "{location}") {
		base = strings.ReplaceAll(base, "{location}", "us-central1")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(base, "/")+path, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if provider.APIKey != "" {
		if google && !strings.HasPrefix(provider.APIKey, "ya29.") {
			req.Header.Set("X-Goog-Api-Key", provider.APIKey)
		} else {
			req.Header.Set("Authorization", "Bearer "+provider.APIKey)
		}
	}
	return req, nil
}

// Speech is spoken audio made by the node's speech model (Admin → AI → Voice): WAV or MP3 bytes, which model made it
// and what it cost. It is shared by the llm plugin (which makes it) and the plugins that bill it.
type Speech struct {
	Audio      []byte `json:"audio"`
	Mime       string `json:"mime"`
	Model      string `json:"model"`
	ProviderID string `json:"provider_id"`
	ModelID    string `json:"model_id"`
	TokensIn   int64  `json:"tokens_in"`
	TokensOut  int64  `json:"tokens_out"`
	// Price is in ledger units, rounded up (0 when the model has no price).
	Price float64 `json:"price"`
}

// Transcription is text made from spoken audio by the node's transcription model
// (Admin → AI → Voice): OpenAI-compatible ASR (e.g. Parakeet V3). Shared by llm and the plugins that bill it.
type Transcription struct {
	Text       string  `json:"text"`
	Model      string  `json:"model"`
	ProviderID string  `json:"provider_id"`
	ModelID    string  `json:"model_id"`
	Seconds    float64 `json:"seconds"`
	// Price is in ledger units, rounded up (0 when the model has no price).
	Price float64 `json:"price"`
}
