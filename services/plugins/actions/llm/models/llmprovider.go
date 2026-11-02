// Package llmprovider models an LLM provider configured by the node admin: the
// API credentials (owned by the admin's account), the models agents may use as
// their backbone and the per-model token prices users are charged.
package llmprovider

import (
	"encoding/json"
	"strings"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
)

// Kind identifies a provider family. Every kind is reached through its
// OpenAI-compatible chat completions endpoint.
type Kind string

// Supported provider kinds.
const (
	KindOpenAI     Kind = "openai"
	KindAnthropic  Kind = "anthropic"
	KindGemini     Kind = "gemini"
	KindVertex     Kind = "vertex"
	KindGrok       Kind = "grok"
	KindOpenRouter Kind = "openrouter"
	KindVercel     Kind = "vercel"
	KindDeepSeek   Kind = "deepseek"
	KindMistral    Kind = "mistral"
	KindGroq       Kind = "groq"
	KindTogether   Kind = "together"
	KindCustom     Kind = "custom"
)

// Preset describes a provider kind: its display name and default
// OpenAI-compatible base URL.
type Preset struct {
	Kind    Kind   `json:"kind"`
	Name    string `json:"name"`
	BaseURL string `json:"base_url"`
}

// Presets lists the known provider kinds in display order.
func Presets() []Preset {
	return []Preset{
		{KindOpenAI, "OpenAI", "https://api.openai.com/v1"},
		{KindAnthropic, "Anthropic", "https://api.anthropic.com/v1"},
		{KindGemini, "Google Gemini", "https://generativelanguage.googleapis.com/v1beta/openai"},
		{KindVertex, "Gemini Enterprise Agent Platform (Vertex AI)", "https://aiplatform.googleapis.com/v1/projects/{project_id}/locations/us-central1/endpoints/openapi"},
		{KindGrok, "xAI Grok", "https://api.x.ai/v1"},
		{KindOpenRouter, "OpenRouter", "https://openrouter.ai/api/v1"},
		{KindVercel, "Vercel AI Gateway", "https://ai-gateway.vercel.sh/v1"},
		{KindDeepSeek, "DeepSeek", "https://api.deepseek.com/v1"},
		{KindMistral, "Mistral", "https://api.mistral.ai/v1"},
		{KindGroq, "Groq", "https://api.groq.com/openai/v1"},
		{KindTogether, "Together AI", "https://api.together.xyz/v1"},
		{KindCustom, "Custom (OpenAI-compatible)", ""},
	}
}

// PresetFor returns the preset of a kind.
func PresetFor(k Kind) (Preset, bool) {
	for _, p := range Presets() {
		if p.Kind == k {
			return p, true
		}
	}
	return Preset{}, false
}

// Model is an LLM model offered by a provider with its token prices, in
// credits per one million tokens.
type Model struct {
	ID          string  `json:"id"`
	Name        string  `json:"name,omitempty"`
	InputPrice  float64 `json:"input_price"`  // credits per 1M input (prompt) tokens
	OutputPrice float64 `json:"output_price"` // credits per 1M output (completion) tokens
	// ContextWindow is the model's input window in tokens; 0 means a known
	// model's published window (llm.ContextWindow), else unknown.
	ContextWindow int `json:"context_window,omitempty"`
	// Capabilities says what the model is for: "chat" (an agent's backbone,
	// the default when empty), "decision" (a decision model such as
	// TypeSafe AI's Jev, which answers typed questions with probabilities
	// and cannot hold a conversation) and/or "embedding" (it turns text into
	// vectors, for the agents' memory; it cannot hold a conversation either).
	Capabilities []string `json:"capabilities,omitempty"`
	// Source is the catalog the model was imported from ("vercel"); empty for
	// a model the admin added by hand. An import updates the models of its
	// source in place, so it never adds a model twice.
	Source string `json:"source,omitempty"`
	// BaseInputPrice and BaseOutputPrice are what the source charges the node
	// (credits per 1M tokens) and Markup the percentage added on top, so a new
	// markup or a new source price can be applied again.
	BaseInputPrice  float64 `json:"base_input_price,omitempty"`
	BaseOutputPrice float64 `json:"base_output_price,omitempty"`
	Markup          float64 `json:"markup,omitempty"`
	// Tags are the features the source reports (vision, tool-use, reasoning,
	// file-input, …); the developer catalog reads them instead of guessing.
	Tags []string `json:"tags,omitempty"`
	// Inputs are the kinds of content the model accepts (text, image, pdf, …).
	Inputs []string `json:"inputs,omitempty"`
	// Units are the prices of what is not counted in tokens (credits per
	// image, second, character or search), and BaseUnits what the source
	// charges for them before the markup.
	Units     *UnitPrices `json:"units,omitempty"`
	BaseUnits *UnitPrices `json:"base_units,omitempty"`
	// Unpriced marks an imported model whose source publishes no price the
	// node can meter: it is not served until the admin sets one.
	Unpriced bool `json:"unpriced,omitempty"`
	// Disabled hides the model: it is not offered for new agents, the
	// decision and memory pickers or the developer API. Agents already set
	// to it keep running on it.
	Disabled bool `json:"disabled,omitempty"`
}

// UnitPrices are prices per unit other than tokens, in credits.
type UnitPrices struct {
	// Image is per generated image.
	Image float64 `json:"image,omitempty"`
	// Second is per second of generated video or of transcribed audio;
	// SecondBy is per second of video at a resolution ("720p"), where it
	// differs by resolution (Second is then the dearest, for a request that
	// names none).
	Second   float64            `json:"second,omitempty"`
	SecondBy map[string]float64 `json:"second_by,omitempty"`
	// Character is per character of text turned into speech.
	Character float64 `json:"character,omitempty"`
	// Search is per reranking request (a search of up to 100 documents).
	Search float64 `json:"search,omitempty"`
}

// Empty reports whether no unit has a price.
func (u *UnitPrices) Empty() bool {
	return u == nil || u.Image <= 0 && u.Second <= 0 && len(u.SecondBy) == 0 && u.Character <= 0 && u.Search <= 0
}

// Model capabilities. Agents run on chat models; the others are served by the
// developer API's endpoints of the same kind (and decision and embedding
// models by the agents' decisions and memory).
const (
	CapabilityChat          = "chat"
	CapabilityDecision      = "decision"
	CapabilityEmbedding     = "embedding"
	CapabilityImage         = "image"
	CapabilityVideo         = "video"
	CapabilitySpeech        = "speech"
	CapabilityTranscription = "transcription"
	CapabilityRerank        = "rerank"
	// CapabilityLive marks a model that hears and answers in voice over one connection (a realtime model).
	CapabilityLive = "live"
)

// Capabilities lists every capability a model can have.
var Capabilities = []string{CapabilityChat, CapabilityDecision, CapabilityEmbedding, CapabilityImage, CapabilityVideo,
	CapabilitySpeech, CapabilityTranscription, CapabilityRerank, CapabilityLive}

// Has reports whether the model has a capability (as the node treats it).
func (m Model) Has(c string) bool { return m.WithCapabilities().has(c) }

// KnownDecisionModel reports whether a model id names a known decision model
// (they are reached through a decision API, never through chat completions).
func KnownDecisionModel(id string) bool {
	id = strings.ToLower(strings.TrimSpace(id))
	name := id[strings.LastIndex(id, "/")+1:]
	return name == "jev" || strings.HasPrefix(name, "jev-") || strings.HasPrefix(name, "decision-") ||
		strings.HasPrefix(id, "typesafe-ai/")
}

// KnownEmbeddingModel reports whether a model id names an embedding model
// (text-embedding-3-small, mistral-embed, nomic-embed-text, …).
func KnownEmbeddingModel(id string) bool {
	return strings.Contains(strings.ToLower(id), "embed")
}

func (m Model) has(c string) bool {
	for _, x := range m.Capabilities {
		if x == c {
			return true
		}
	}
	return false
}

// WithCapabilities returns the model with its capabilities as the node treats
// them (a model saved without any is a chat model, or a known decision model).
func (m Model) WithCapabilities() Model {
	if len(m.Capabilities) == 0 {
		if KnownDecisionModel(m.ID) {
			m.Capabilities = []string{CapabilityDecision}
		} else if KnownEmbeddingModel(m.ID) {
			m.Capabilities = []string{CapabilityEmbedding}
		} else {
			m.Capabilities = []string{CapabilityChat}
		}
	}
	return m
}

// Decision reports whether the model can serve as the node's decision model.
func (m Model) Decision() bool { return m.WithCapabilities().has(CapabilityDecision) }

// Embedding reports whether the model can embed the agents' memories.
func (m Model) Embedding() bool { return m.WithCapabilities().has(CapabilityEmbedding) }

// Chat reports whether agents can run on the model: every model without
// capabilities is a chat model, unless it is a known decision or embedding
// model.
func (m Model) Chat() bool {
	if len(m.Capabilities) == 0 {
		return !KnownDecisionModel(m.ID) && !KnownEmbeddingModel(m.ID)
	}
	return m.has(CapabilityChat)
}

// Provider is an admin-configured LLM provider.
type Provider struct {
	entity.Entity
	// OwnerID is the account that owns the API key (the node admin who set it);
	// LLM usage charges are paid to its wallet.
	OwnerID   identity.ID `db:"owner_id" json:"owner_id"`
	Name      string      `db:"name" json:"name"`
	Kind      Kind        `db:"kind" json:"kind"`
	BaseURL   string      `db:"base_url" json:"base_url"`
	APIKey    string      `db:"api_key" json:"-"`
	Enabled   bool        `db:"enabled" json:"enabled"`
	IsDefault bool        `db:"is_default" json:"is_default"`
	Models    string      `db:"models" json:"-"` // JSON []Model
	// ImageModel is the model used by the image_generate tool (empty = none)
	// and ImagePrice the credits charged per generated image.
	ImageModel string  `db:"image_model" json:"image_model,omitempty"`
	ImagePrice float64 `db:"image_price" json:"image_price,omitempty"`
}

// ParseModels decodes the provider's model list.
func (p *Provider) ParseModels() []Model {
	var out []Model
	if strings.TrimSpace(p.Models) == "" {
		return nil
	}
	_ = json.Unmarshal([]byte(p.Models), &out)
	return out
}

// SetModels encodes the provider's model list.
func (p *Provider) SetModels(models []Model) {
	b, _ := json.Marshal(models)
	p.Models = string(b)
}

// ChatModels returns the models agents can run on, in order (not the disabled ones).
func (p *Provider) ChatModels() []Model {
	out := []Model{}
	for _, m := range p.ParseModels() {
		if m.Chat() && !m.Disabled {
			out = append(out, m)
		}
	}
	return out
}

// Model returns the provider's model with the given id.
func (p *Provider) Model(id string) (Model, bool) {
	for _, m := range p.ParseModels() {
		if m.ID == id {
			return m, true
		}
	}
	return Model{}, false
}

// KeyPreview returns a masked form of the API key safe to show in the UI.
func (p *Provider) KeyPreview() string {
	k := p.APIKey
	if k == "" {
		return ""
	}
	if len(k) <= 8 {
		return "••••"
	}
	return k[:4] + "••••" + k[len(k)-4:]
}
