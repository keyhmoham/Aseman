package llm

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

var (
	gcpProjectCache sync.Map
	consumerRegex   = regexp.MustCompile(`projects/([0-9a-zA-Z._-]+)`)
)

// ResolveVertexURL substitutes {location} and {project_id} placeholders
// in a Vertex AI OpenAPI base URL.
func ResolveVertexURL(ctx context.Context, rawURL, apiKey string) string {
	if rawURL == "" {
		return rawURL
	}
	loc := os.Getenv("TRADERA_VERTEX_LOCATION")
	if loc == "" {
		loc = "us-central1"
	}
	url := strings.ReplaceAll(rawURL, "{location}", loc)

	if !strings.Contains(url, "{project_id}") {
		return url
	}

	project := os.Getenv("TRADERA_VERTEX_PROJECT")
	if project == "" {
		project = os.Getenv("GOOGLE_CLOUD_PROJECT")
	}
	if project == "" {
		project = os.Getenv("GCP_PROJECT")
	}
	if project == "" && apiKey != "" {
		project = AutoDetectGCPProject(ctx, apiKey)
	}
	if project != "" {
		url = strings.ReplaceAll(url, "{project_id}", project)
	}
	return url
}

// AutoDetectGCPProject inspects the Google API error metadata returned when
// probing with the given key to find its bound GCP project number/ID.
func AutoDetectGCPProject(ctx context.Context, apiKey string) string {
	if apiKey == "" {
		return ""
	}
	if v, ok := gcpProjectCache.Load(apiKey); ok {
		if s, ok := v.(string); ok && s != "" {
			return s
		}
	}

	probeCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()

	probeBody := []byte(`{"model":"gemini-2.5-flash","messages":[{"role":"user","content":"hi"}]}`)
	req, err := http.NewRequestWithContext(probeCtx, http.MethodPost,
		"https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", bytes.NewReader(probeBody))
	if err != nil {
		return ""
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+apiKey)

	client := &http.Client{Timeout: 4 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	m := consumerRegex.FindSubmatch(body)
	if len(m) > 1 {
		proj := string(m[1])
		gcpProjectCache.Store(apiKey, proj)
		return proj
	}
	return ""
}
