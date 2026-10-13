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
)

const defaultImageModel = "gpt-image-1"

var imageClient = &http.Client{Timeout: 5 * time.Minute}

// GenerateImage creates an image from a prompt with the image model of the
// given provider (the default image provider when empty), through the
// OpenAI-compatible images API. It returns the bytes, their MIME type and the
// provider's price per image (credits), which the caller bills.
func (s *Service) GenerateImage(ctx context.Context, provider, prompt, size string) ([]byte, string, float64, error) {
	if strings.TrimSpace(prompt) == "" {
		return nil, "", 0, errs.InvalidArgument("image prompt required")
	}
	p, err := s.ResolveImage(ctx, provider)
	if err != nil {
		return nil, "", 0, err
	}
	model := p.ImageModel
	if model == "" {
		model = defaultImageModel
	}
	body := map[string]any{"model": model, "prompt": prompt, "n": 1}
	if size != "" {
		body["size"] = size
	}
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(p.BaseURL, "/")+"/images/generations", bytes.NewReader(raw))
	if err != nil {
		return nil, "", 0, err
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
		return nil, "", 0, errs.Wrap(errs.CodeUnavailable, err, "image request")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, "", 0, err
	}
	if resp.StatusCode >= 400 {
		return nil, "", 0, errs.New(errs.CodeUnavailable, fmt.Sprintf("image model returned %d: %s", resp.StatusCode, clip(string(data), 300)))
	}
	var out struct {
		Data []struct {
			B64JSON string `json:"b64_json"`
			URL     string `json:"url"`
		} `json:"data"`
	}
	if err := json.Unmarshal(data, &out); err != nil || len(out.Data) == 0 {
		return nil, "", 0, errs.New(errs.CodeUnavailable, "image model returned no image")
	}
	var img []byte
	switch d := out.Data[0]; {
	case d.B64JSON != "":
		if img, err = base64.StdEncoding.DecodeString(d.B64JSON); err != nil {
			return nil, "", 0, errs.Wrap(errs.CodeUnavailable, err, "decode image")
		}
	case d.URL != "":
		// Older image models return a short-lived URL instead of bytes.
		get, err := http.NewRequestWithContext(ctx, http.MethodGet, d.URL, nil)
		if err != nil {
			return nil, "", 0, err
		}
		r, err := imageClient.Do(get)
		if err != nil {
			return nil, "", 0, errs.Wrap(errs.CodeUnavailable, err, "download image")
		}
		defer r.Body.Close()
		if img, err = io.ReadAll(r.Body); err != nil {
			return nil, "", 0, err
		}
	default:
		return nil, "", 0, errs.New(errs.CodeUnavailable, "image model returned no image data")
	}
	return img, http.DetectContentType(img), p.ImagePrice, nil
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
