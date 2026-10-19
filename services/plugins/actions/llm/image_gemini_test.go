package llm

import (
	"context"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"testing"

	llmprovider "github.com/tradera/tradera/plugins/actions/llm/models"
)

func TestGeminiImageRouting(t *testing.T) {
	vertex := &llmprovider.Provider{Kind: llmprovider.KindVertex, BaseURL: "https://aiplatform.googleapis.com/v1/projects/p/locations/us-central1/endpoints/openapi"}
	cases := []struct {
		p     *llmprovider.Provider
		model string
		want  bool
	}{
		{vertex, "gemini-2.5-flash-image", true},
		{vertex, "google/gemini-3-pro-image-preview", true},
		{vertex, "gemini-2.5-flash", false},
		{&llmprovider.Provider{Kind: llmprovider.KindOpenAI, BaseURL: "https://api.openai.com/v1"}, "gpt-image-1", false},
		{&llmprovider.Provider{Kind: llmprovider.KindOpenAI, BaseURL: "https://api.openai.com/v1"}, "gemini-2.5-flash-image", false},
	}
	for _, c := range cases {
		if got := usesGeminiImageAPI(c.p, c.model); got != c.want {
			t.Errorf("usesGeminiImageAPI(%s, %s) = %v, want %v", c.p.Kind, c.model, got, c.want)
		}
	}
}

func TestGeminiImageURL(t *testing.T) {
	got := geminiImageURL("https://aiplatform.googleapis.com/v1/projects/p/locations/us-central1/endpoints/openapi", "gemini-2.5-flash-image")
	if want := "https://aiplatform.googleapis.com/v1/projects/p/locations/us-central1/publishers/google/models/gemini-2.5-flash-image:generateContent"; got != want {
		t.Errorf("vertex url = %s", got)
	}
	got = geminiImageURL("https://generativelanguage.googleapis.com/v1beta/openai", "gemini-2.5-flash-image")
	if want := "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent"; got != want {
		t.Errorf("gemini url = %s", got)
	}
}

func TestGenerateGeminiImage(t *testing.T) {
	png := []byte("\x89PNG\r\n\x1a\nfake")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/projects/p/locations/l/publishers/google/models/gemini-2.5-flash-image:generateContent" {
			t.Errorf("path = %s", r.URL.Path)
		}
		if r.Header.Get("X-Goog-Api-Key") != "key" {
			t.Errorf("api key header = %q", r.Header.Get("X-Goog-Api-Key"))
		}
		w.Write([]byte(`{"candidates":[{"content":{"parts":[{"text":"ok"},{"inlineData":{"mimeType":"image/png","data":"` + base64.StdEncoding.EncodeToString(png) + `"}}]}}],"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":1290}}`))
	}))
	defer srv.Close()
	p := &llmprovider.Provider{Kind: llmprovider.KindVertex, APIKey: "key", BaseURL: srv.URL + "/v1/projects/p/locations/l/endpoints/openapi"}
	img, in, out, err := generateGeminiImage(context.Background(), p, "gemini-2.5-flash-image", "a banana")
	if err != nil || string(img) != string(png) || in != 12 || out != 1290 {
		t.Fatalf("img=%q in=%d out=%d err=%v", img, in, out, err)
	}
}

func TestImageCost(t *testing.T) {
	// Priced by tokens only (Gemini image models): 1290 output tokens at
	// 30,000,000 units per 1M tokens ($30/1M) is 38,700 units (~$0.039).
	tokens := llmprovider.Model{ID: "gemini-2.5-flash-image", InputPrice: 300000, OutputPrice: 30000000}
	if got := imageCost(tokens, 1, 12, 1290); got != 38704 {
		t.Errorf("token-priced cost = %v", got)
	}
	// Priced per image only: the tokens are ignored.
	flat := llmprovider.Model{ID: "dall-e-3", Units: &llmprovider.UnitPrices{Image: 40000}}
	if got := imageCost(flat, 1, 500, 500); got != 40000 {
		t.Errorf("per-image cost = %v", got)
	}
	// Both: a price per image plus its tokens.
	both := llmprovider.Model{ID: "gpt-image-1", InputPrice: 5000000, OutputPrice: 40000000, Units: &llmprovider.UnitPrices{Image: 1000}}
	if got := imageCost(both, 1, 100, 1000); got != 1000+500+40000 {
		t.Errorf("mixed cost = %v", got)
	}
	if got := imageCost(llmprovider.Model{ID: "free"}, 1, 10, 10); got != 0 {
		t.Errorf("unpriced cost = %v", got)
	}
}
