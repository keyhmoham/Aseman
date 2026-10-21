package llm

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/aseman/aseman/plugins/actions/llm/models"
)

// vercelFeed is a slice of Vercel's real model list, in its shape.
func vercelFeed(gptInput string) string {
	gone := time.Now().Add(-time.Hour).UnixMilli()
	return `{"object":"list","data":[
	{"id":"openai/gpt-5-mini","name":"GPT-5 mini","type":"language","context_window":400000,
	 "tags":["reasoning","tool-use","vision","file-input","implicit-caching"],"modalities":{"input":["text","image","pdf"],"output":["text"]},
	 "pricing":{"input":"` + gptInput + `","output":"0.000002","input_tiers":[{"cost":"0.00000025","min":0}]}},
	{"id":"typesafe-ai/jev","name":"Jev","type":"evaluation","modalities":{"input":["text"],"output":["text"]},"pricing":{"input":"0.000000042","output":"0"}},
	{"id":"openai/text-embedding-3-small","name":"text-embedding-3-small","type":"embedding","modalities":{"input":["text"],"output":["text"]},"pricing":{"input":"0.00000002"}},
	{"id":"bfl/flux-2-pro","name":"FLUX.2 Pro","type":"image","modalities":{"input":["text"],"output":["image"]},"pricing":{"image":"0.08"}},
	{"id":"bfl/flux-2-flex","name":"FLUX.2 Flex","type":"image","modalities":{"input":["text"],"output":["image"]},"pricing":{}},
	{"id":"alibaba/wan-v2.6-t2v","name":"Wan 2.6","type":"video","modalities":{"input":["text"],"output":["video"]},
	 "pricing":{"video_duration_pricing":[{"resolution":"720p","cost_per_second":"0.1"},{"resolution":"1080p","cost_per_second":"0.15"}]}},
	{"id":"bytedance/seedance-2.0","type":"video","modalities":{"input":["text"],"output":["video"]},"pricing":{"video_token_pricing":{"tiers":[]}}},
	{"id":"fish-audio/s1","name":"S1","type":"speech","modalities":{"input":["text"],"output":["audio"]},"pricing":{"input":"0.000015","speech_input_character_cost":"0.000015"}},
	{"id":"openai/whisper-1","name":"Whisper","type":"transcription","modalities":{"input":["audio"],"output":["text"]},"pricing":{"input":"0.0000000001","transcription_duration_cost_per_second":"0.0001"}},
	{"id":"cohere/rerank-v3.5","name":"Rerank 3.5","type":"reranking","modalities":{"input":["text"],"output":["text"]},"pricing":{}},
	{"id":"voyage/rerank-2.5","name":"Rerank 2.5","type":"reranking","modalities":{"input":["text"],"output":["text"]},"pricing":{"input":"0.00000005"}},
	{"id":"google/gemini-3.8-live","type":"realtime","modalities":{"input":["audio"],"output":["audio"]},"pricing":{"input":"0.00000075"}},
	{"id":"openai/gpt-4o-transcribe","type":"transcription","deprecated_at":` + itoa64(gone) + `,"modalities":{"input":["audio"],"output":["text"]},"pricing":{}},
	{"id":"openai/gpt-3.5-turbo","name":"GPT-3.5","type":"language","deprecated_at":` + itoa64(gone) + `,"modalities":{"input":["text"],"output":["text"]},"pricing":{"input":"0.0000005","output":"0.0000015"}}
	]}`
}

func itoa64(n int64) string {
	var b strings.Builder
	if n == 0 {
		return "0"
	}
	digits := []byte{}
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	b.Write(digits)
	return b.String()
}

func TestImportVercelAddsUpdatesAndNeverDuplicates(t *testing.T) {
	s, ctx, admin := harness(t)
	gptInput := atomic.Value{}
	gptInput.Store("0.00000025")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(vercelFeed(gptInput.Load().(string))))
	}))
	defer srv.Close()
	s.VercelURL = srv.URL

	if _, err := s.ImportVercel(ctx, "", 20); err == nil || !strings.Contains(err.Error(), "Vercel AI Gateway provider") {
		t.Fatalf("an import needs a Vercel provider first: %v", err)
	}
	p, err := s.Set(ctx, admin, ProviderInput{Kind: llmprovider.KindVercel, APIKey: "vck-123456789",
		Models: []llmprovider.Model{{ID: "typesafe-ai/jev", Name: "Jev (ours)", InputPrice: 1}}})
	if err != nil {
		t.Fatal(err)
	}

	res, err := s.ImportVercel(ctx, "", 20)
	if err != nil {
		t.Fatal(err)
	}
	if res.Added != 10 || res.Updated != 1 || res.Skipped["realtime"] != 1 || res.Skipped["deprecated"] != 2 ||
		strings.Join(res.NeedPrice, ",") != "bfl/flux-2-flex,bytedance/seedance-2.0,cohere/rerank-v3.5" {
		t.Fatalf("first import: %+v", res)
	}
	got, _ := s.Get(ctx, p.ID)
	list := got.ParseModels()
	if len(list) != 11 {
		t.Fatalf("models: %+v", list)
	}
	byID := map[string]llmprovider.Model{}
	for _, m := range list {
		byID[m.ID] = m
	}
	gpt := byID["openai/gpt-5-mini"]
	// $0.25/M and $2/M plus 20%: $0.30/M and $2.40/M.
	if gpt.BaseInputPrice != 250_000 || gpt.InputPrice != 300_000 || gpt.OutputPrice != 2_400_000 || gpt.Markup != 20 || gpt.Source != SourceVercel ||
		gpt.ContextWindow != 400000 || !gpt.Chat() || gpt.Name != "GPT-5 mini" || len(gpt.Tags) == 0 || len(gpt.Inputs) != 3 {
		t.Fatalf("gpt: %+v", gpt)
	}
	jev := byID["typesafe-ai/jev"]
	if jev.Name != "Jev (ours)" || jev.InputPrice != 50_400 || jev.OutputPrice != 0 || !jev.Decision() || jev.Chat() {
		t.Fatalf("an existing model is priced again, keeping the admin's name: %+v", jev)
	}
	if emb := byID["openai/text-embedding-3-small"]; !emb.Embedding() || emb.InputPrice != 24_000 {
		t.Fatalf("embedding: %+v", emb)
	}

	if m := byID["bfl/flux-2-pro"]; !m.Has("image") || m.Units.Image != 96_000 || m.Unpriced {
		t.Fatalf("$0.08 an image plus 20%%: %+v", m)
	}
	if m := byID["alibaba/wan-v2.6-t2v"]; m.Units.SecondBy["720p"] != 120_000 || m.Units.SecondBy["1080p"] != 180_000 || m.Units.Second != 180_000 {
		t.Fatalf("video by resolution, the dearest for none: %+v", m.Units)
	}
	if m := byID["fish-audio/s1"]; m.Units.Character != 18 || m.InputPrice != 0 {
		t.Fatalf("speech by the character only: %+v %+v", m, m.Units)
	}
	if m := byID["openai/whisper-1"]; m.Units.Second != 120 || !m.Has("transcription") {
		t.Fatalf("transcription by the second: %+v", m.Units)
	}
	if m := byID["voyage/rerank-2.5"]; m.InputPrice != 60_000 || !m.Has("rerank") {
		t.Fatalf("rerank by its tokens: %+v", m)
	}
	if m := byID["cohere/rerank-v3.5"]; !m.Unpriced || m.InputPrice != 0 || m.Units != nil {
		t.Fatalf("no published price: imported as needing one: %+v", m)
	}

	// The admin prices a model Vercel publishes no price for: an import keeps it.
	got, _ = s.Get(ctx, p.ID)
	priced := got.ParseModels()
	for i := range priced {
		if priced[i].ID == "cohere/rerank-v3.5" {
			priced[i].Unpriced, priced[i].Units = false, &llmprovider.UnitPrices{Search: 2_500}
		}
		if priced[i].ID == "fish-audio/s1" {
			priced[i].Disabled = true
		}
	}
	got.SetModels(priced)
	if err := s.saveProvider(ctx, got, false); err != nil {
		t.Fatal(err)
	}

	again, err := s.ImportVercel(ctx, "", 20)
	if err != nil || again.Added != 0 || again.Updated != 0 || again.Unchanged != 11 || len(again.NeedPrice) != 2 {
		t.Fatalf("importing again changes nothing: %+v %v", again, err)
	}

	gptInput.Store("0.0000002")
	moved, err := s.ImportVercel(ctx, p.ID.String(), 50)
	if err != nil || moved.Added != 0 || moved.Updated != 8 {
		t.Fatalf("a new price and markup (the 3 unpriced keep theirs): %+v %v", moved, err)
	}
	got, _ = s.Get(ctx, p.ID)
	if n := len(got.ParseModels()); n != 11 {
		t.Fatalf("never duplicated: %d models", n)
	}
	if f, _ := got.Model("fish-audio/s1"); !f.Disabled {
		t.Fatal("a model the admin disabled stays disabled through an import")
	}
	if c, _ := got.Model("cohere/rerank-v3.5"); c.Units == nil || c.Units.Search != 2_500 || c.Unpriced {
		t.Fatalf("the admin's price stays: %+v", c)
	}
	m, _ := got.Model("openai/gpt-5-mini")
	if m.InputPrice != 300_000 || m.OutputPrice != 3_000_000 || m.Markup != 50 {
		t.Fatalf("$0.20/M and $2/M plus 50%%: %+v", m)
	}

	if _, err := s.ImportVercel(ctx, "", -5); err == nil {
		t.Fatal("a negative markup is refused")
	}
	other, _ := s.Set(ctx, admin, ProviderInput{Kind: llmprovider.KindOpenAI, APIKey: "sk-openai-123456"})
	if _, err := s.ImportVercel(ctx, other.ID.String(), 10); err == nil {
		t.Fatal("only a Vercel provider takes Vercel's models")
	}
}

func TestOfferingsCarryWhatTheSourceReports(t *testing.T) {
	s, ctx, admin := harness(t)
	if _, err := s.Set(ctx, admin, ProviderInput{Kind: llmprovider.KindVercel, APIKey: "vck-123456789", Models: []llmprovider.Model{
		{ID: "openai/gpt-5-mini", Name: "GPT-5 mini", InputPrice: 1, Capabilities: []string{"chat"}, Tags: []string{"vision"}, Inputs: []string{"text", "image"}}}}); err != nil {
		t.Fatal(err)
	}
	got, _ := s.Offerings(ctx)
	if len(got) != 1 || got[0].Label != "GPT-5 mini" || len(got[0].Tags) != 1 || len(got[0].Inputs) != 2 {
		t.Fatalf("%+v", got)
	}
}
