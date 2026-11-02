package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"mime/multipart"
	"net/http"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	llmprovider "github.com/aseman/aseman/plugins/actions/llm/models"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// Transcription is text made from spoken audio by the node's transcription
// model (Admin → AI → Voice): OpenAI-compatible /audio/transcriptions (e.g. Parakeet V3).
type Transcription = vmm.Transcription

// Transcribe turns spoken audio into text with the node's transcription model.
func (s *Service) Transcribe(ctx context.Context, audio []byte, mime string) (*Transcription, error) {
	if len(audio) == 0 {
		return nil, errs.InvalidArgument("audio required")
	}
	roles, err := s.VoiceRoles(ctx)
	if err != nil {
		return nil, err
	}
	r := roles[llmprovider.VoiceTranscription]
	if !r.Enabled {
		return nil, errs.New(errs.CodeUnavailable, "no transcription model is set")
	}
	p, m, err := s.voiceModel(ctx, llmprovider.VoiceTranscription, r.ProviderID, r.ModelID)
	if err != nil {
		return nil, errs.New(errs.CodeUnavailable, "the transcription model is unavailable: "+err.Error())
	}
	text, seconds, callError := openAITranscribe(ctx, p, m.ID, audio, mime)
	if callError != nil {
		return nil, callError
	}
	price := transcriptionCost(m, seconds)
	return &Transcription{
		Text: text, Model: p.Name + " / " + m.ID, ProviderID: p.ID.String(), ModelID: m.ID,
		Seconds: seconds, Price: price,
	}, nil
}

func transcriptionCost(m llmprovider.Model, seconds float64) float64 {
	if m.Units == nil || m.Units.Second <= 0 || seconds <= 0 {
		return 0
	}
	c := seconds * m.Units.Second
	if c <= 0 {
		return 0
	}
	return math.Ceil(c - 1e-9)
}

func openAITranscribe(ctx context.Context, p *llmprovider.Provider, model string, audio []byte, mime string) (string, float64, error) {
	if mime == "" {
		mime = "audio/wav"
	}
	ext := "wav"
	switch {
	case strings.Contains(mime, "mpeg"), strings.Contains(mime, "mp3"):
		ext = "mp3"
	case strings.Contains(mime, "webm"):
		ext = "webm"
	case strings.Contains(mime, "ogg"):
		ext = "ogg"
	case strings.Contains(mime, "mp4"), strings.Contains(mime, "m4a"):
		ext = "m4a"
	}
	var body bytes.Buffer
	w := multipart.NewWriter(&body)
	_ = w.WriteField("model", model)
	_ = w.WriteField("response_format", "json")
	part, err := w.CreateFormFile("file", "speech."+ext)
	if err != nil {
		return "", 0, err
	}
	if _, err := part.Write(audio); err != nil {
		return "", 0, err
	}
	_ = w.Close()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(imageBaseURL(ctx, p), "/")+"/audio/transcriptions", &body)
	if err != nil {
		return "", 0, err
	}
	req.Header.Set("Content-Type", w.FormDataContentType())
	setSpeechAuth(req, p, false)
	client := &http.Client{Timeout: 90 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", 0, errs.Wrap(errs.CodeUnavailable, err, "the transcription model could not be reached")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return "", 0, errs.Wrap(errs.CodeUnavailable, err, "the transcription model's answer was cut short")
	}
	if resp.StatusCode >= 300 {
		return "", 0, errs.New(errs.CodeUnavailable, fmt.Sprintf("the transcription model refused the request (%d): %s", resp.StatusCode, clip(strings.Join(strings.Fields(string(data)), " "), 300)))
	}
	var out struct {
		Text     string  `json:"text"`
		Duration float64 `json:"duration"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		// Plain text response from some providers.
		text := strings.TrimSpace(string(data))
		if text == "" {
			return "", 0, errs.Wrap(errs.CodeUnavailable, err, "decode transcription")
		}
		return text, estimateAudioSeconds(audio, mime), nil
	}
	text := strings.TrimSpace(out.Text)
	if text == "" {
		return "", 0, errs.New(errs.CodeUnavailable, "the transcription model returned no text")
	}
	sec := out.Duration
	if sec <= 0 {
		sec = estimateAudioSeconds(audio, mime)
	}
	return text, sec, nil
}

// estimateAudioSeconds is a rough length for billing when the provider omits duration.
func estimateAudioSeconds(audio []byte, mime string) float64 {
	if strings.Contains(mime, "wav") && len(audio) > 44 {
		// 16-bit mono 16 kHz PCM after a 44-byte header is typical for our client.
		return float64(len(audio)-44) / (16000 * 2)
	}
	// ~16 kbps average for compressed formats.
	return float64(len(audio)) / 2000
}
