package developer

import (
	"context"
	"math"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/tradera/tradera/plugins/actions/llm/dto"
)

// Model types: what a model is for decides its endpoint and what it is charged by.
const (
	TypeLanguage      = "language"
	TypeImage         = "image"
	TypeVideo         = "video"
	TypeSpeech        = "speech"
	TypeTranscription = "transcription"
	TypeEmbedding     = "embedding"
	TypeDecision      = "decision"
	TypeRerank        = "rerank"
)

// PriceLine is one thing a model charges for, in ledger units (a millionth of
// a dollar) per what Per says.
type PriceLine struct {
	Label string  `json:"label"`
	Units float64 `json:"units"`
	Per   string  `json:"per"`
}

// Stats are live figures for a provider's endpoint, when known.
type Stats struct {
	LatencyMs       float64 `json:"latencyMs,omitempty"`
	TokensPerSecond float64 `json:"tokensPerSecond,omitempty"`
}

// Endpoint is one provider's way of serving a model.
type Endpoint struct {
	Provider     string      `json:"provider"`
	ProviderName string      `json:"providerName"`
	UpstreamID   string      `json:"upstreamId"`
	Prices       []PriceLine `json:"prices"`
	IsDefault    bool        `json:"isDefault"`
	Stats        *Stats      `json:"stats,omitempty"`

	offering dto.Offering
}

// Modalities say what a model takes and what it produces.
type Modalities struct {
	Input  []string `json:"input"`
	Output []string `json:"output"`
}

// CatalogModel is one model, listed once with every provider that serves it.
type CatalogModel struct {
	ID            string     `json:"id"`
	Name          string     `json:"name"`
	Creator       string     `json:"creator"`
	Type          string     `json:"type"`
	Modalities    Modalities `json:"modalities"`
	Capabilities  []string   `json:"capabilities"`
	ContextWindow int        `json:"contextWindow,omitempty"`
	Endpoints     []Endpoint `json:"endpoints"`
}

var slugRX = regexp.MustCompile(`[^a-z0-9]+`)

func slugify(text string) string {
	return strings.Trim(slugRX.ReplaceAllString(strings.ToLower(text), "-"), "-")
}

type creatorRule struct {
	rx      *regexp.Regexp
	creator string
}

var creatorRules = []creatorRule{
	{regexp.MustCompile(`^(gemini|gemma|imagen|veo|palm|text-embedding-0|nano-banana)`), "google"},
	{regexp.MustCompile(`^(gpt|o\d|dall-e|whisper|tts|sora|chatgpt|text-embedding-3|codex)`), "openai"},
	{regexp.MustCompile(`^claude`), "anthropic"},
	{regexp.MustCompile(`^(llama|meta-llama)`), "meta"},
	{regexp.MustCompile(`^(mistral|mixtral|codestral|pixtral|ministral)`), "mistral"},
	{regexp.MustCompile(`^deepseek`), "deepseek"},
	{regexp.MustCompile(`^grok`), "xai"},
	{regexp.MustCompile(`^(qwen|wan)`), "alibaba"},
	{regexp.MustCompile(`^kimi`), "moonshotai"},
	{regexp.MustCompile(`^(jev|decision)`), "typesafe"},
}

var creatorAlias = map[string]string{"meta-llama": "meta", "mistralai": "mistral", "x-ai": "xai", "qwen": "alibaba", "moonshot": "moonshotai"}

// canonicalID names a model by its creator whatever id a provider uses:
// `google/gemini-3.8-flash`, `models/gemini-3.8-flash` and `gemini-3.8-flash`
// are one model.
func canonicalID(raw, providerKind string) (id, creator, base string) {
	base = strings.TrimPrefix(strings.ToLower(strings.TrimSpace(raw)), "models/")
	if at := strings.Index(base, "/"); at > 0 {
		creator, base = base[:at], base[at+1:]
	}
	if alias, ok := creatorAlias[creator]; ok {
		creator = alias
	}
	if creator == "" {
		for _, r := range creatorRules {
			if r.rx.MatchString(base) {
				creator = r.creator
				break
			}
		}
	}
	if creator == "" {
		creator = slugify(providerKind)
	}
	if creator == "" {
		creator = "other"
	}
	return creator + "/" + base, creator, base
}

var (
	visionRX    = regexp.MustCompile(`gemini|gpt-4|gpt-5|claude|llama-?4|vl\b|vision|pixtral|grok-[2-9]`)
	reasoningRX = regexp.MustCompile(`\bo\d\b|thinking|reason|r1\b|gpt-5|gemini-[\d.]+-pro|claude.*(opus|sonnet)`)
)

func modalitiesOf(typ, base string) Modalities {
	switch typ {
	case TypeLanguage:
		if visionRX.MatchString(base) {
			return Modalities{Input: []string{"text", "image", "file"}, Output: []string{"text"}}
		}
		return Modalities{Input: []string{"text"}, Output: []string{"text"}}
	case TypeImage:
		return Modalities{Input: []string{"text", "image"}, Output: []string{"image"}}
	case TypeVideo:
		return Modalities{Input: []string{"text", "image"}, Output: []string{"video"}}
	case TypeSpeech:
		return Modalities{Input: []string{"text"}, Output: []string{"audio"}}
	case TypeTranscription:
		return Modalities{Input: []string{"audio"}, Output: []string{"text"}}
	case TypeRerank:
		return Modalities{Input: []string{"text"}, Output: []string{"text"}}
	}
	return Modalities{Input: []string{"text"}, Output: []string{"text"}}
}

// sourceTag is what a source catalog's feature tag means here.
var sourceTag = map[string]string{"tool-use": "tools", "structured-output": "json", "reasoning": "reasoning", "vision": "vision",
	"implicit-caching": "caching", "explicit-caching": "caching"}

// sourceInput is what a source catalog's input modality is called here.
var sourceInput = map[string]string{"text": "text", "image": "image", "pdf": "file", "file": "file", "audio": "audio", "video": "video"}

// described is a model's modalities and capabilities as its source catalog
// reports them, when it does (an imported model); ok is false otherwise.
func described(typ string, o dto.Offering) (Modalities, []string, bool) {
	if len(o.Tags) == 0 && len(o.Inputs) == 0 {
		return Modalities{}, nil, false
	}
	mods := Modalities{Input: []string{}, Output: modalitiesOf(typ, "").Output}
	seen := map[string]bool{}
	for _, in := range o.Inputs {
		if m, ok := sourceInput[in]; ok && !seen[m] {
			seen[m] = true
			mods.Input = append(mods.Input, m)
		}
	}
	if len(mods.Input) == 0 {
		mods.Input = []string{"text"}
	}
	caps := []string{}
	if typ != TypeLanguage {
		return mods, caps, true
	}
	caps = append(caps, "streaming")
	have := map[string]bool{"streaming": true}
	for _, t := range o.Tags {
		if c, ok := sourceTag[t]; ok && !have[c] {
			have[c] = true
			caps = append(caps, c)
		}
	}
	return mods, caps, true
}

func capabilitiesOf(typ, base string) []string {
	if typ != TypeLanguage {
		return []string{}
	}
	caps := []string{"streaming", "tools", "json"}
	if visionRX.MatchString(base) {
		caps = append(caps, "vision")
	}
	if reasoningRX.MatchString(base) {
		caps = append(caps, "reasoning")
	}
	return caps
}

func typeOf(o dto.Offering) string {
	switch o.Type {
	case "image", "embedding", "decision", "video", "speech", "transcription", "rerank":
		return o.Type
	}
	return TypeLanguage
}

// priceLines are what a model is charged by, as the catalog shows them.
func priceLines(typ string, o dto.Offering) []PriceLine {
	tokens := func(out bool) []PriceLine {
		lines := []PriceLine{{Label: "Input", Units: o.InputPrice, Per: "1M tokens"}}
		if out {
			lines = append(lines, PriceLine{Label: "Output", Units: o.OutputPrice, Per: "1M tokens"})
		}
		return lines
	}
	switch typ {
	case TypeImage:
		var lines []PriceLine
		if o.PerImage > 0 {
			lines = append(lines, PriceLine{Label: "Per image", Units: o.PerImage, Per: "image"})
		}
		if o.InputPrice > 0 || o.OutputPrice > 0 || len(lines) == 0 {
			lines = append(lines, tokens(true)...)
		}
		return lines
	case TypeVideo:
		if len(o.PerSecondBy) == 0 {
			return []PriceLine{{Label: "Per second", Units: o.PerSecond, Per: "second"}}
		}
		res := make([]string, 0, len(o.PerSecondBy))
		for r := range o.PerSecondBy {
			res = append(res, r)
		}
		sort.Slice(res, func(i, j int) bool { return resolutionHeight(res[i]) < resolutionHeight(res[j]) })
		lines := make([]PriceLine, 0, len(res))
		for _, r := range res {
			lines = append(lines, PriceLine{Label: "Per second (" + r + ")", Units: o.PerSecondBy[r], Per: "second"})
		}
		return lines
	case TypeSpeech:
		return []PriceLine{{Label: "Characters", Units: o.PerCharacter * 1e6, Per: "1M characters"}}
	case TypeTranscription:
		return []PriceLine{{Label: "Audio", Units: o.PerSecond * 60, Per: "minute"}}
	case TypeRerank:
		if o.PerSearch > 0 {
			return []PriceLine{{Label: "Per search", Units: o.PerSearch, Per: "search"}}
		}
		return tokens(false)
	case TypeEmbedding:
		return tokens(false)
	}
	return tokens(true)
}

// resolutionHeight is the height a resolution names: "720p", "1280x720" → 720.
func resolutionHeight(r string) int {
	r = strings.ToLower(strings.TrimSpace(r))
	switch r {
	case "2k":
		return 1440
	case "4k":
		return 2160
	case "8k":
		return 4320
	}
	if i := strings.IndexByte(r, 'x'); i > 0 {
		r = r[i+1:]
	}
	n := 0
	for _, c := range strings.TrimSuffix(r, "p") {
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
	}
	return n
}

func priceScore(e Endpoint) float64 {
	n := 0.0
	for _, p := range e.Prices {
		n += p.Units
	}
	return n
}

// BuildCatalog merges the providers' models into one list: a model several
// providers serve is one entry with an endpoint each, the default provider's
// first and exactly one marked as the default.
func BuildCatalog(offerings []dto.Offering) []CatalogModel {
	byID := map[string]*CatalogModel{}
	fromSource := map[string]bool{}
	var order []string
	for _, o := range offerings {
		id, creator, base := canonicalID(o.Model, o.Kind)
		typ := typeOf(o)
		ep := Endpoint{Provider: o.Slug, ProviderName: o.Name, UpstreamID: o.Model, Prices: priceLines(typ, o), IsDefault: o.IsDefault, offering: o}
		if m, ok := byID[id]; ok {
			dup := false
			for _, e := range m.Endpoints {
				dup = dup || e.Provider == ep.Provider
			}
			if !dup {
				m.Endpoints = append(m.Endpoints, ep)
			}
			if o.ContextWindow > m.ContextWindow {
				m.ContextWindow = o.ContextWindow
			}
			// What a source catalog reports beats the guess from the name.
			if mods, caps, ok := described(typ, o); ok && !fromSource[id] {
				m.Modalities, m.Capabilities, fromSource[id] = mods, caps, true
			}
			continue
		}
		mods, caps, ok := described(typ, o)
		if !ok {
			mods, caps = modalitiesOf(typ, base), capabilitiesOf(typ, base)
		}
		fromSource[id] = ok
		name := prettyName(base)
		if ok && strings.TrimSpace(o.Label) != "" {
			name = strings.TrimSpace(o.Label)
		}
		byID[id] = &CatalogModel{ID: id, Name: name, Creator: creator, Type: typ, Modalities: mods,
			Capabilities: caps, ContextWindow: o.ContextWindow, Endpoints: []Endpoint{ep}}
		order = append(order, id)
	}
	out := make([]CatalogModel, 0, len(order))
	for _, id := range order {
		m := byID[id]
		sort.SliceStable(m.Endpoints, func(i, j int) bool {
			a, b := m.Endpoints[i], m.Endpoints[j]
			if a.IsDefault != b.IsDefault {
				return a.IsDefault
			}
			return priceScore(a) < priceScore(b)
		})
		for i := range m.Endpoints {
			m.Endpoints[i].IsDefault = i == 0
		}
		out = append(out, *m)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Creator != out[j].Creator {
			return out[i].Creator < out[j].Creator
		}
		return out[i].ID < out[j].ID
	})
	return out
}

func prettyName(base string) string {
	words := regexp.MustCompile(`[-_]`).Split(base, -1)
	for i, w := range words {
		if w != "" && !(w[0] >= '0' && w[0] <= '9') {
			words[i] = strings.ToUpper(w[:1]) + w[1:]
		}
	}
	name := strings.Join(words, " ")
	name = regexp.MustCompile(`\bGpt\b`).ReplaceAllString(name, "GPT")
	return regexp.MustCompile(`\bAi\b`).ReplaceAllString(name, "AI")
}

// Catalog is the unified model list, rebuilt from the providers at most every
// few seconds: admins' changes show up at once without a database read per call.
func (s *Service) Catalog(ctx context.Context) ([]CatalogModel, error) {
	s.catalogMu.Lock()
	defer s.catalogMu.Unlock()
	if s.catalog != nil && s.now().Sub(s.catalogAt) < 10*time.Second {
		return s.catalog, nil
	}
	offerings, err := s.Providers.Offerings(ctx)
	if err != nil {
		return nil, err
	}
	s.catalog, s.catalogAt = BuildCatalog(offerings), s.now()
	return s.catalog, nil
}

// FindModel finds a model by its canonical id or a bare id (`gemini-3.8-flash`),
// or by what a provider calls it.
func FindModel(catalog []CatalogModel, ref string) *CatalogModel {
	id := strings.ToLower(strings.TrimSpace(ref))
	for i := range catalog {
		if catalog[i].ID == id {
			return &catalog[i]
		}
	}
	for i := range catalog {
		if strings.HasSuffix(catalog[i].ID, "/"+id) {
			return &catalog[i]
		}
	}
	for i := range catalog {
		for _, e := range catalog[i].Endpoints {
			if strings.ToLower(e.UpstreamID) == id {
				return &catalog[i]
			}
		}
	}
	return nil
}

// usd is ledger units as dollars.
func usd(units float64) float64 { return units / 1_000_000 }

// units is dollars as ledger units.
func units(usd float64) float64 { return math.Round(usd * 1_000_000) }
