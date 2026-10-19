package llm

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/tradera/tradera/pkg/errs"
	llmprovider "github.com/tradera/tradera/plugins/actions/llm/models"
)

const defaultImageModel = "gpt-image-1"

var imageClient = &http.Client{Timeout: 5 * time.Minute}

// GenerateImage creates an image from a prompt and returns the bytes, their
// MIME type, its price in ledger units (which the caller bills) and, for the
// admin log, the image model with the tokens the provider reported.
//
// The model is the node's image model (Admin → Image model), whatever model
// the agent itself runs on, and it is priced like any model on the Models
// page: per image, per token reported by the provider, or both. Until that
// setting is first saved, the image model of a provider (the agent's own when
// given) is used at its flat price per image, as before.
func (s *Service) GenerateImage(ctx context.Context, provider, prompt, size string) ([]byte, string, float64, string, int64, int64, error) {
	if strings.TrimSpace(prompt) == "" {
		return nil, "", 0, "", 0, 0, errs.InvalidArgument("image prompt required")
	}
	p, m, legacy, err := s.imageTarget(ctx, provider)
	if err != nil {
		return nil, "", 0, "", 0, 0, err
	}
	var img []byte
	var in, out int64
	if usesGeminiImageAPI(p, m.ID) {
		img, in, out, err = generateGeminiImage(ctx, p, m.ID, prompt)
	} else {
		img, in, out, err = generateOpenAIImage(ctx, p, m.ID, prompt, size)
	}
	if err != nil {
		return nil, "", 0, "", 0, 0, err
	}
	price := imageCost(m, 1, in, out)
	if legacy {
		price = p.ImagePrice
	}
	return img, http.DetectContentType(img), price, p.Name + " / " + m.ID, in, out, nil
}

// imageTarget picks the provider and model an image is generated with.
// legacy is true when it comes from a provider's own image model field (the
// node's image model was never set).
func (s *Service) imageTarget(ctx context.Context, provider string) (*llmprovider.Provider, llmprovider.Model, bool, error) {
	d, err := s.ImageSetting(ctx)
	if err != nil {
		return nil, llmprovider.Model{}, false, err
	}
	if d.Enabled {
		p, m, err := s.imageModel(ctx, d.ProviderID, d.ModelID)
		if err != nil {
			return nil, llmprovider.Model{}, false, errs.New(errs.CodeUnavailable, "the image model is unavailable: "+err.Error())
		}
		return p, m, false, nil
	}
	if !d.UpdatedAt.IsZero() {
		return nil, llmprovider.Model{}, false, errs.New(errs.CodeUnavailable, "image generation is off; the node admin can turn it on under Image model")
	}
	p, err := s.ResolveImage(ctx, provider)
	if err != nil {
		return nil, llmprovider.Model{}, false, err
	}
	model := p.ImageModel
	if model == "" {
		model = defaultImageModel
	}
	return p, llmprovider.Model{ID: model}, true, nil
}

// imageBaseURL is the provider's base URL with Vertex placeholders resolved.
func imageBaseURL(ctx context.Context, p *llmprovider.Provider) string {
	if p.Kind == llmprovider.KindVertex {
		return ResolveVertexURL(ctx, p.BaseURL, p.APIKey)
	}
	return p.BaseURL
}

// generateOpenAIImage generates through the OpenAI-compatible images API and
// returns the image with the tokens the provider reports (0 when it reports
// none, as for models priced per image).
func generateOpenAIImage(ctx context.Context, p *llmprovider.Provider, model, prompt, size string) ([]byte, int64, int64, error) {
	body := map[string]any{"model": model, "prompt": prompt, "n": 1}
	if size != "" {
		body["size"] = size
	}
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(imageBaseURL(ctx, p), "/")+"/images/generations", bytes.NewReader(raw))
	if err != nil {
		return nil, 0, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	if p.APIKey != "" {
		if (p.Kind == "vertex" || p.Kind == "gemini" || strings.Contains(p.BaseURL, "googleapis.com")) && !strings.HasPrefix(p.APIKey, "ya29.") {
			req.Header.Set("X-Goog-Api-Key", p.APIKey)
		} else {
			req.Header.Set("Authorization", "Bearer "+p.APIKey)
		}
	}
	resp, err := imageClient.Do(req)
	if err != nil {
		return nil, 0, 0, errs.Wrap(errs.CodeUnavailable, err, "image request")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, 0, 0, err
	}
	if resp.StatusCode >= 400 {
		return nil, 0, 0, errs.New(errs.CodeUnavailable, fmt.Sprintf("image model returned %d: %s", resp.StatusCode, clip(string(data), 300)))
	}
	var out struct {
		Data []struct {
			B64JSON string `json:"b64_json"`
			URL     string `json:"url"`
		} `json:"data"`
		Usage struct {
			InputTokens  int64 `json:"input_tokens"`
			OutputTokens int64 `json:"output_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(data, &out); err != nil || len(out.Data) == 0 {
		return nil, 0, 0, errs.New(errs.CodeUnavailable, "image model returned no image")
	}
	var img []byte
	switch d := out.Data[0]; {
	case d.B64JSON != "":
		if img, err = base64.StdEncoding.DecodeString(d.B64JSON); err != nil {
			return nil, 0, 0, errs.Wrap(errs.CodeUnavailable, err, "decode image")
		}
	case d.URL != "":
		// Older image models return a short-lived URL instead of bytes.
		get, err := http.NewRequestWithContext(ctx, http.MethodGet, d.URL, nil)
		if err != nil {
			return nil, 0, 0, err
		}
		r, err := imageClient.Do(get)
		if err != nil {
			return nil, 0, 0, errs.Wrap(errs.CodeUnavailable, err, "download image")
		}
		defer r.Body.Close()
		if img, err = io.ReadAll(r.Body); err != nil {
			return nil, 0, 0, err
		}
	default:
		return nil, 0, 0, errs.New(errs.CodeUnavailable, "image model returned no image data")
	}
	return img, out.Usage.InputTokens, out.Usage.OutputTokens, nil
}

// usesGeminiImageAPI reports whether the provider's image model is a Gemini
// image model (for example gemini-2.5-flash-image, "Nano Banana") on Google's
// own API or Vertex AI. Those models do not sit behind the OpenAI-style
// /images/generations endpoint: they generate through generateContent. Every
// other provider and model keeps the OpenAI-compatible path.
func usesGeminiImageAPI(p *llmprovider.Provider, model string) bool {
	google := p.Kind == llmprovider.KindVertex || p.Kind == llmprovider.KindGemini || strings.Contains(p.BaseURL, "googleapis.com")
	m := strings.ToLower(strings.TrimPrefix(model, "google/"))
	return google && strings.HasPrefix(m, "gemini") && strings.Contains(m, "image")
}

// geminiImageURL derives the generateContent URL from the provider's
// OpenAI-compatible base URL: Vertex "…/locations/L/endpoints/openapi" becomes
// "…/locations/L/publishers/google/models/MODEL:generateContent", and the
// Gemini API "…/v1beta/openai" becomes "…/v1beta/models/MODEL:generateContent".
func geminiImageURL(base, model string) string {
	model = strings.TrimPrefix(model, "google/")
	base = strings.TrimRight(base, "/")
	switch {
	case strings.HasSuffix(base, "/endpoints/openapi"):
		return strings.TrimSuffix(base, "/endpoints/openapi") + "/publishers/google/models/" + model + ":generateContent"
	case strings.HasSuffix(base, "/openai"):
		return strings.TrimSuffix(base, "/openai") + "/models/" + model + ":generateContent"
	}
	return base + "/models/" + model + ":generateContent"
}

// generateGeminiImage asks a Gemini image model for one image and returns it
// with the prompt and output tokens Google reports (what it bills by).
func generateGeminiImage(ctx context.Context, p *llmprovider.Provider, model, prompt string) ([]byte, int64, int64, error) {
	base := imageBaseURL(ctx, p)
	raw, _ := json.Marshal(map[string]any{
		"contents":         []any{map[string]any{"role": "user", "parts": []any{map[string]any{"text": prompt}}}},
		"generationConfig": map[string]any{"responseModalities": []string{"TEXT", "IMAGE"}},
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, geminiImageURL(base, model), bytes.NewReader(raw))
	if err != nil {
		return nil, 0, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	if p.APIKey != "" {
		if strings.HasPrefix(p.APIKey, "ya29.") {
			req.Header.Set("Authorization", "Bearer "+p.APIKey)
		} else {
			req.Header.Set("X-Goog-Api-Key", p.APIKey)
		}
	}
	resp, err := imageClient.Do(req)
	if err != nil {
		return nil, 0, 0, errs.Wrap(errs.CodeUnavailable, err, "image request")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, 0, 0, err
	}
	if resp.StatusCode >= 400 {
		return nil, 0, 0, errs.New(errs.CodeUnavailable, fmt.Sprintf("image model returned %d: %s", resp.StatusCode, clip(string(data), 300)))
	}
	var out struct {
		Candidates []struct {
			Content struct {
				Parts []struct {
					InlineData *struct {
						Data string `json:"data"`
					} `json:"inlineData"`
					InlineDataSnake *struct {
						Data string `json:"data"`
					} `json:"inline_data"`
				} `json:"parts"`
			} `json:"content"`
		} `json:"candidates"`
		UsageMetadata struct {
			PromptTokenCount     int64 `json:"promptTokenCount"`
			CandidatesTokenCount int64 `json:"candidatesTokenCount"`
		} `json:"usageMetadata"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, 0, 0, errs.New(errs.CodeUnavailable, "image model returned an unreadable response")
	}
	for _, c := range out.Candidates {
		for _, part := range c.Content.Parts {
			d := part.InlineData
			if d == nil {
				d = part.InlineDataSnake
			}
			if d == nil || d.Data == "" {
				continue
			}
			img, err := base64.StdEncoding.DecodeString(d.Data)
			if err != nil {
				return nil, 0, 0, errs.Wrap(errs.CodeUnavailable, err, "decode image")
			}
			return img, out.UsageMetadata.PromptTokenCount, out.UsageMetadata.CandidatesTokenCount, nil
		}
	}
	return nil, 0, 0, errs.New(errs.CodeUnavailable, "image model returned no image (it may have refused the prompt)")
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
