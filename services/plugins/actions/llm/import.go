package llm

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/llm/models"
)

// VercelModelsURL is Vercel AI Gateway's public model list.
const VercelModelsURL = "https://ai-gateway.vercel.sh/v1/models"

// SourceVercel marks a model imported from Vercel AI Gateway.
const SourceVercel = "vercel"

// maxMarkup bounds the markup an import applies, in percent.
const maxMarkup = 1000

var importClient = &http.Client{Timeout: 30 * time.Second}

// vercelModel is one entry of Vercel's model list. Prices are dollars per
// token, as strings.
type vercelModel struct {
	ID            string   `json:"id"`
	Name          string   `json:"name"`
	Type          string   `json:"type"`
	ContextWindow int      `json:"context_window"`
	Tags          []string `json:"tags"`
	Modalities    struct {
		Input []string `json:"input"`
	} `json:"modalities"`
	Pricing vercelPricing `json:"pricing"`
	// DeprecatedAt is when Vercel stops serving the model, in milliseconds.
	DeprecatedAt int64 `json:"deprecated_at"`
}

// vercelPricing is what Vercel lists a model's price as: dollars per token,
// image, second or character, as strings. A field it leaves out has no price
// in that unit; "0" is free.
type vercelPricing struct {
	Input  string `json:"input"`
	Output string `json:"output"`
	Image  string `json:"image"`
	// ImageBySize prices an image by its size (or an extra operation, which
	// is not metered).
	ImageBySize []struct {
		Size      string `json:"size"`
		Operation string `json:"operation"`
		Cost      string `json:"cost"`
	} `json:"image_dimension_quality_pricing"`
	VideoBySecond []struct {
		Resolution    string `json:"resolution"`
		CostPerSecond string `json:"cost_per_second"`
	} `json:"video_duration_pricing"`
	SpeechCharacter     string `json:"speech_input_character_cost"`
	TranscriptionSecond string `json:"transcription_duration_cost_per_second"`
}

// vercelCapability is what a Vercel model type is on this node. Realtime
// models talk over a WebSocket the node does not proxy, so they are not
// imported.
var vercelCapability = map[string]string{
	"language":      llmprovider.CapabilityChat,
	"evaluation":    llmprovider.CapabilityDecision,
	"embedding":     llmprovider.CapabilityEmbedding,
	"image":         llmprovider.CapabilityImage,
	"video":         llmprovider.CapabilityVideo,
	"speech":        llmprovider.CapabilitySpeech,
	"transcription": llmprovider.CapabilityTranscription,
	"reranking":     llmprovider.CapabilityRerank,
}

// vercelPrice is a model's price as the node meters it, before the markup:
// tokens (credits per 1M) and units. priced is false when Vercel publishes no
// price in a unit the node can meter for the model's kind (FLUX images, Cohere
// reranking, token-priced speech or transcription, token-priced video): the
// model is then imported as needing a price.
func vercelPrice(capability string, p vercelPricing) (in, out float64, units *llmprovider.UnitPrices, priced bool) {
	has := func(v string) bool { return strings.TrimSpace(v) != "" }
	tokens := has(p.Input) || has(p.Output)
	u := &llmprovider.UnitPrices{}
	switch capability {
	case llmprovider.CapabilityChat, llmprovider.CapabilityDecision, llmprovider.CapabilityEmbedding:
		return perMillion(p.Input), perMillion(p.Output), nil, tokens
	case llmprovider.CapabilityImage:
		u.Image = perUnit(p.Image)
		if !has(p.Image) {
			// Priced by size only: an image is charged at the dearest size.
			for _, s := range p.ImageBySize {
				if s.Size != "" && perUnit(s.Cost) > u.Image {
					u.Image = perUnit(s.Cost)
				}
			}
		}
		if u.Image > 0 || has(p.Image) {
			return perMillion(p.Input), perMillion(p.Output), u, true
		}
		// A multimodal image model priced by its tokens.
		return perMillion(p.Input), perMillion(p.Output), nil, tokens
	case llmprovider.CapabilityVideo:
		for _, r := range p.VideoBySecond {
			if r.Resolution == "" || !has(r.CostPerSecond) {
				continue
			}
			if u.SecondBy == nil {
				u.SecondBy = map[string]float64{}
			}
			v := perUnit(r.CostPerSecond)
			u.SecondBy[strings.ToLower(r.Resolution)] = v
			u.Second = math.Max(u.Second, v)
		}
		return 0, 0, u, len(u.SecondBy) > 0
	case llmprovider.CapabilitySpeech:
		u.Character = perUnit(p.SpeechCharacter)
		return 0, 0, u, has(p.SpeechCharacter)
	case llmprovider.CapabilityTranscription:
		u.Second = perUnit(p.TranscriptionSecond)
		return 0, 0, u, has(p.TranscriptionSecond)
	case llmprovider.CapabilityRerank:
		// Reranking reports no usage: its tokens are counted from the request.
		return perMillion(p.Input), 0, nil, has(p.Input)
	}
	return 0, 0, nil, false
}

// markedUnits is unit prices with the markup added.
func markedUnits(base *llmprovider.UnitPrices, markup float64) *llmprovider.UnitPrices {
	if base == nil {
		return nil
	}
	out := &llmprovider.UnitPrices{Image: marked(base.Image, markup), Second: marked(base.Second, markup),
		Character: marked(base.Character, markup), Search: marked(base.Search, markup)}
	for k, v := range base.SecondBy {
		if out.SecondBy == nil {
			out.SecondBy = map[string]float64{}
		}
		out.SecondBy[k] = marked(v, markup)
	}
	return out
}

// ImportResult says what an import did.
type ImportResult struct {
	Provider  map[string]any `json:"provider"`
	Markup    float64        `json:"markup"`
	Added     int            `json:"added"`
	Updated   int            `json:"updated"`
	Unchanged int            `json:"unchanged"`
	// Skipped counts the source's models not imported, by reason (their type, or "deprecated").
	Skipped map[string]int `json:"skipped"`
	// Gone are models imported before that the source no longer lists. They
	// are kept (agents may use them); the admin removes them.
	Gone []string `json:"gone"`
	// NeedPrice are models the source publishes no meterable price for and
	// nobody has priced yet: they are not served until the admin sets one.
	NeedPrice []string `json:"need_price"`
}

// perMillion turns a per-token dollar price into credits per 1M tokens
// (1,000,000 ledger units a dollar).
func perMillion(perToken string) float64 {
	v, err := strconv.ParseFloat(strings.TrimSpace(perToken), 64)
	if err != nil || v <= 0 || math.IsInf(v, 0) || math.IsNaN(v) {
		return 0
	}
	return math.Round(v*1e12*100) / 100
}

// perUnit turns a dollar price per image, second or character into credits.
func perUnit(usd string) float64 {
	v, err := strconv.ParseFloat(strings.TrimSpace(usd), 64)
	if err != nil || v <= 0 || math.IsInf(v, 0) || math.IsNaN(v) {
		return 0
	}
	return math.Round(v*1e6*100) / 100
}

// marked is a base price with the markup added, to a hundredth of a unit.
func marked(base, markup float64) float64 {
	return math.Round(base*(1+markup/100)*100) / 100
}

// fetchVercel reads Vercel's model list.
func (s *Service) fetchVercel(ctx context.Context) ([]vercelModel, error) {
	url := s.VercelURL
	if url == "" {
		url = VercelModelsURL
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := importClient.Do(req)
	if err != nil {
		return nil, errs.New(errs.CodeUnavailable, "could not reach Vercel AI Gateway: "+err.Error())
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return nil, errs.New(errs.CodeUnavailable, "Vercel's model list was cut short")
	}
	if resp.StatusCode != http.StatusOK {
		return nil, errs.New(errs.CodeUnavailable, fmt.Sprintf("Vercel AI Gateway answered %d", resp.StatusCode))
	}
	var body struct {
		Data []vercelModel `json:"data"`
	}
	if err := json.Unmarshal(data, &body); err != nil || len(body.Data) == 0 {
		return nil, errs.New(errs.CodeUnavailable, "Vercel's model list could not be read")
	}
	return body.Data, nil
}

// vercelProvider is the provider an import goes to: the one named, else the
// only Vercel AI Gateway provider.
func (s *Service) vercelProvider(ctx context.Context, providerID string) (*llmprovider.Provider, error) {
	if strings.TrimSpace(providerID) != "" {
		id, err := identity.Parse(providerID)
		if err != nil {
			return nil, errs.InvalidArgument("invalid provider id")
		}
		p, err := s.Get(ctx, id)
		if err != nil {
			return nil, err
		}
		if p.Kind != llmprovider.KindVercel {
			return nil, errs.InvalidArgument(p.Name + " is not a Vercel AI Gateway provider")
		}
		return p, nil
	}
	all, err := s.List(ctx)
	if err != nil {
		return nil, err
	}
	var found []*llmprovider.Provider
	for i := range all {
		if all[i].Kind == llmprovider.KindVercel {
			found = append(found, &all[i])
		}
	}
	switch len(found) {
	case 0:
		return nil, errs.New(errs.CodeConflict, "add a Vercel AI Gateway provider with its API key under Providers first")
	case 1:
		return found[0], nil
	}
	return nil, errs.InvalidArgument("there are several Vercel AI Gateway providers: choose one")
}

// ImportVercel brings Vercel AI Gateway's models (all but realtime ones) into
// a Vercel provider, at Vercel's price plus [markup] percent. A
// model the provider already has (by id) is updated in place: its prices
// follow Vercel's current price and the new markup, so importing again never
// adds a model twice. Prices are Vercel's base rates: long-context tiers and
// cache discounts are not modelled.
func (s *Service) ImportVercel(ctx context.Context, providerID string, markup float64) (*ImportResult, error) {
	if markup < 0 || markup > maxMarkup || math.IsNaN(markup) {
		return nil, errs.InvalidArgument(fmt.Sprintf("markup must be between 0 and %d percent", maxMarkup))
	}
	p, err := s.vercelProvider(ctx, providerID)
	if err != nil {
		return nil, err
	}
	feed, err := s.fetchVercel(ctx)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	res := &ImportResult{Markup: markup, Skipped: map[string]int{}, Gone: []string{}, NeedPrice: []string{}}
	list := p.ParseModels()
	at := map[string]int{}
	for i, m := range list {
		at[m.ID] = i
	}
	listed := map[string]bool{}
	for _, v := range feed {
		v.ID = strings.TrimSpace(v.ID)
		if v.ID == "" {
			continue
		}
		capability, ok := vercelCapability[v.Type]
		if !ok {
			res.Skipped[v.Type]++
			continue
		}
		if v.DeprecatedAt > 0 && time.UnixMilli(v.DeprecatedAt).Before(now) {
			res.Skipped["deprecated"]++
			continue
		}
		if listed[v.ID] {
			continue
		}
		listed[v.ID] = true
		in, out, units, priced := vercelPrice(capability, v.Pricing)
		next := llmprovider.Model{ID: v.ID, Name: strings.TrimSpace(v.Name), ContextWindow: v.ContextWindow,
			Capabilities: []string{capability}, Source: SourceVercel, Tags: v.Tags, Inputs: v.Modalities.Input}
		if priced {
			next.Markup, next.BaseInputPrice, next.BaseOutputPrice, next.BaseUnits = markup, in, out, units
			next.InputPrice, next.OutputPrice, next.Units = marked(in, markup), marked(out, markup), markedUnits(units, markup)
		} else {
			next.Unpriced = true
		}
		i, exists := at[v.ID]
		if !exists {
			at[v.ID] = len(list)
			list = append(list, next)
			res.Added++
			continue
		}
		old := list[i]
		// The name the model has is kept (the admin may have renamed it), and
		// so is whether the admin disabled it.
		if old.Name != "" {
			next.Name = old.Name
		}
		next.Disabled = old.Disabled
		// Without a price from the source, the one the model has stays (the
		// admin's), and so does whether it still needs one.
		if !priced {
			next.InputPrice, next.OutputPrice, next.Units, next.Unpriced = old.InputPrice, old.OutputPrice, old.Units, old.Unpriced
			next.Markup, next.BaseInputPrice, next.BaseOutputPrice, next.BaseUnits = old.Markup, old.BaseInputPrice, old.BaseOutputPrice, old.BaseUnits
		}
		if sameModel(old, next) {
			res.Unchanged++
			continue
		}
		list[i] = next
		res.Updated++
	}
	for _, m := range list {
		if m.Source == SourceVercel && !listed[m.ID] {
			res.Gone = append(res.Gone, m.ID)
		}
		if m.Unpriced {
			res.NeedPrice = append(res.NeedPrice, m.ID)
		}
	}
	sort.Strings(res.Gone)
	sort.Strings(res.NeedPrice)
	if res.Added+res.Updated > 0 {
		clean, err := cleanModels(list)
		if err != nil {
			return nil, err
		}
		p.SetModels(clean)
		p.UpdatedAt = time.Now().UTC()
		if err := s.saveProvider(ctx, p, false); err != nil {
			return nil, err
		}
	}
	res.Provider = view(p)
	return res, nil
}

func sameModel(a, b llmprovider.Model) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return string(x) == string(y)
}
