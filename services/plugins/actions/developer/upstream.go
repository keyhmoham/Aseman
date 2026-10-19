package developer

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

// Doer makes the calls to the model providers.
type Doer interface {
	Do(*http.Request) (*http.Response, error)
}

func defaultDoer() Doer {
	return &http.Client{Transport: &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		MaxIdleConnsPerHost:   32,
		IdleConnTimeout:       90 * time.Second,
		ResponseHeaderTimeout: 120 * time.Second,
	}}
}

// upstreamRequest is a call to one provider's OpenAI-compatible endpoint
// (path: "/chat/completions", "/embeddings", "/images/generations") for the
// model the provider calls it, with the provider's key, which never leaves the
// node.
func upstreamRequest(ctx context.Context, e Endpoint, path string, body map[string]any) (*http.Request, error) {
	o := e.offering
	isVertex := o.Kind == "vertex" || strings.Contains(o.BaseURL, "aiplatform.googleapis.com")
	google := isVertex || o.Kind == "gemini" || strings.Contains(o.BaseURL, "googleapis.com")
	model := o.Model
	if isVertex && !strings.Contains(model, "/") {
		model = "google/" + model
	}
	payload := make(map[string]any, len(body)+1)
	for k, v := range body {
		payload[k] = v
	}
	payload["model"] = model
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	base := o.BaseURL
	if isVertex && strings.Contains(base, "{location}") {
		base = strings.ReplaceAll(base, "{location}", "us-central1")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(base, "/")+path, bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if o.APIKey != "" {
		if google && !strings.HasPrefix(o.APIKey, "ya29.") {
			req.Header.Set("X-Goog-Api-Key", o.APIKey)
		} else {
			req.Header.Set("Authorization", "Bearer "+o.APIKey)
		}
	}
	return req, nil
}
