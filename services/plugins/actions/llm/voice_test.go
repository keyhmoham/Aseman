package llm

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	llmprovider "github.com/aseman/aseman/plugins/actions/llm/models"
)

func TestPCMIsWrappedAsAPlayableWAV(t *testing.T) {
	wav := pcmWAV([]byte{1, 2, 3, 4}, 24000)
	if string(wav[0:4]) != "RIFF" || string(wav[8:12]) != "WAVE" || string(wav[36:40]) != "data" {
		t.Fatalf("header: %q", wav[:44])
	}
	if binary.LittleEndian.Uint32(wav[24:28]) != 24000 || binary.LittleEndian.Uint32(wav[40:44]) != 4 || len(wav) != 48 {
		t.Fatalf("rate %d, data %d, size %d", binary.LittleEndian.Uint32(wav[24:28]), binary.LittleEndian.Uint32(wav[40:44]), len(wav))
	}
	for mime, want := range map[string]int{"audio/L16;codec=pcm;rate=16000": 16000, "audio/L16; rate=44100": 44100, "audio/pcm": 24000, "": 24000} {
		if got := pcmRate(mime); got != want {
			t.Errorf("%q: %d", mime, got)
		}
	}
}

// A Gemini speech model is asked through generateContent for AUDIO with the chosen voice, and its raw PCM comes back as a WAV.
func TestGeminiSpeechAsksForAudioWithTheChosenVoice(t *testing.T) {
	var got map[string]any
	var path string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.Path
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &got)
		pcm := base64.StdEncoding.EncodeToString([]byte{0, 1, 2, 3})
		_, _ = w.Write([]byte(`{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"audio/L16;codec=pcm;rate=24000","data":"` + pcm + `"}}]}}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":90}}`))
	}))
	defer srv.Close()
	p := &llmprovider.Provider{Kind: llmprovider.KindGemini, BaseURL: srv.URL + "/v1beta/openai", APIKey: "k"}
	audio, mime, in, out, err := geminiSpeech(context.Background(), p, "gemini-tts", "Puck", "Hello there.")
	if err != nil || mime != "audio/wav" || in != 7 || out != 90 || string(audio[:4]) != "RIFF" {
		t.Fatalf("audio %d bytes, %s, %d/%d tokens, %v", len(audio), mime, in, out, err)
	}
	if path != "/v1beta/models/gemini-tts:generateContent" {
		t.Fatalf("path %s", path)
	}
	cfg := got["generationConfig"].(map[string]any)
	voice := cfg["speechConfig"].(map[string]any)["voiceConfig"].(map[string]any)["prebuiltVoiceConfig"].(map[string]any)["voiceName"]
	if cfg["responseModalities"].([]any)[0] != "AUDIO" || voice != "Puck" || !strings.Contains(string(mustJSON(got["contents"])), "Hello there.") {
		t.Fatalf("request %v", got)
	}
}

func TestSpeechRefusalCarriesWhatTheProviderSaid(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(400)
		_, _ = w.Write([]byte(`{"error":{"message":"voice not found"}}`))
	}))
	defer srv.Close()
	p := &llmprovider.Provider{Kind: llmprovider.KindGemini, BaseURL: srv.URL + "/v1beta/openai", APIKey: "k"}
	if _, _, _, _, err := geminiSpeech(context.Background(), p, "m", "Nope", "hi"); err == nil || !strings.Contains(err.Error(), "voice not found") {
		t.Fatalf("error: %v", err)
	}
}

func TestOpenAISpeechAsksTheAudioEndpointForMP3(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &got)
		if r.URL.Path != "/v1/audio/speech" || r.Header.Get("Authorization") != "Bearer k" {
			w.WriteHeader(404)
			return
		}
		_, _ = w.Write([]byte("ID3audio"))
	}))
	defer srv.Close()
	p := &llmprovider.Provider{Kind: llmprovider.KindOpenAI, BaseURL: srv.URL + "/v1", APIKey: "k"}
	audio, mime, _, _, err := openAISpeech(context.Background(), p, "tts-1", "", "Hello")
	if err != nil || mime != "audio/mpeg" || string(audio) != "ID3audio" || got["voice"] != "alloy" || got["input"] != "Hello" {
		t.Fatalf("%q %s %v %v", audio, mime, got, err)
	}
}

func mustJSON(v any) []byte { b, _ := json.Marshal(v); return b }

// Speech is priced by tokens (Gemini: text in, audio out), by characters, or both. The ledger counts 1,000,000 units a dollar.
func TestSpeechIsPricedByTokensByCharactersOrBoth(t *testing.T) {
	text := strings.Repeat("a", 1000)
	// Gemini TTS: $0.50 in and $6.00 out per 1M tokens: 500,000 and 6,000,000 units per 1M tokens.
	// 250 tokens in and 4,000 of audio out: 125 + 24,000 units ($0.024125).
	tokens := llmprovider.Model{InputPrice: 500_000, OutputPrice: 6_000_000}
	if got := speechCost(tokens, text, 250, 4000); got != 24_125 {
		t.Errorf("tokens: %v", got)
	}
	// OpenAI tts-1: $15 per 1M characters is 15 units a character: 1,000 characters cost $0.015.
	chars := llmprovider.Model{Units: &llmprovider.UnitPrices{Character: 15}}
	if got := speechCost(chars, text, 0, 0); got != 15_000 {
		t.Errorf("characters: %v", got)
	}
	both := llmprovider.Model{InputPrice: 1_000_000, Units: &llmprovider.UnitPrices{Character: 0.5}}
	if got := speechCost(both, text, 10, 0); got != 510 {
		t.Errorf("both: %v", got)
	}
	if got := speechCost(llmprovider.Model{}, text, 100, 100); got != 0 {
		t.Errorf("unpriced: %v", got)
	}
}

// Gemini 3.8 speech models answer with a WAV file already: it is passed on as it is, never wrapped a second time.
func TestAWAVFromTheModelIsNotWrappedAgain(t *testing.T) {
	wav := pcmWAV([]byte{9, 8, 7, 6}, 24000)
	if got := playableAudio(wav, "audio/wav"); string(got) != string(wav) {
		t.Fatalf("a WAV was changed: %d bytes became %d", len(wav), len(got))
	}
	raw := playableAudio([]byte{1, 2, 3, 4}, "audio/L16;codec=pcm;rate=16000")
	if string(raw[:4]) != "RIFF" || binary.LittleEndian.Uint32(raw[24:28]) != 16000 || len(raw) != 48 {
		t.Fatalf("raw PCM was not wrapped at its rate: %d bytes", len(raw))
	}
}
