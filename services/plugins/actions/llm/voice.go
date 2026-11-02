package llm

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/pkg/errs"
	llmprovider "github.com/aseman/aseman/plugins/actions/llm/models"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// The voice models of a live voice chat (Admin → AI → Voice). Each role (speech, transcription, live) has its own model,
// picked from the models marked with that kind on the Models page, and is priced at that model's prices. A role without a
// model keeps what the app does without one: the device's own speech recognition and voices.

const voiceTable = "llm_voice"

func (s *Service) voiceID() string { return s.K.NodeID().String() + "voice" }

// capabilityOf is the model capability a voice role needs.
func capabilityOf(role string) string {
	switch role {
	case llmprovider.VoiceSpeech:
		return llmprovider.CapabilitySpeech
	case llmprovider.VoiceTranscription:
		return llmprovider.CapabilityTranscription
	case llmprovider.VoiceLive:
		return llmprovider.CapabilityLive
	}
	return ""
}

// VoiceRoles are the stored choices, a role with none included as off.
func (s *Service) VoiceRoles(ctx context.Context) (map[string]llmprovider.VoiceRole, error) {
	out := map[string]llmprovider.VoiceRole{}
	for _, r := range llmprovider.VoiceRoles {
		out[r] = llmprovider.VoiceRole{}
	}
	var d llmprovider.VoiceSetting
	err := s.R.GetString(ctx, voiceTable, s.voiceID(), &d)
	if errs.CodeOf(err) == errs.CodeNotFound {
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	var stored map[string]llmprovider.VoiceRole
	if json.Unmarshal([]byte(d.Roles), &stored) == nil {
		for role, v := range stored {
			if _, known := out[role]; known {
				out[role] = v
			}
		}
	}
	return out, nil
}

// VoiceInput is the admin form of one role.
type VoiceInput struct {
	Role       string `json:"role"`
	Enabled    bool   `json:"enabled"`
	ProviderID string `json:"provider_id"`
	ModelID    string `json:"model_id"`
	Voice      string `json:"voice"`
}

// SetVoiceRole stores the model chosen for one role. Turning it on needs an enabled provider with an API key and one
// of its models marked for that role.
func (s *Service) SetVoiceRole(ctx context.Context, in VoiceInput) error {
	if capabilityOf(in.Role) == "" {
		return errs.InvalidArgument("role must be speech, transcription or live")
	}
	in.ProviderID, in.ModelID, in.Voice = strings.TrimSpace(in.ProviderID), strings.TrimSpace(in.ModelID), strings.TrimSpace(in.Voice)
	if in.Enabled || in.ProviderID != "" {
		if in.ProviderID == "" || in.ModelID == "" {
			return errs.InvalidArgument("pick a provider and one of its " + in.Role + " models")
		}
		if _, _, err := s.voiceModel(ctx, in.Role, in.ProviderID, in.ModelID); err != nil {
			return err
		}
	}
	roles, err := s.VoiceRoles(ctx)
	if err != nil {
		return err
	}
	roles[in.Role] = llmprovider.VoiceRole{Enabled: in.Enabled, ProviderID: in.ProviderID, ModelID: in.ModelID, Voice: in.Voice}
	raw, _ := json.Marshal(roles)
	var d llmprovider.VoiceSetting
	err = s.R.GetString(ctx, voiceTable, s.voiceID(), &d)
	creating := errs.CodeOf(err) == errs.CodeNotFound
	if err != nil && !creating {
		return err
	}
	d.ID, d.Roles, d.UpdatedAt = s.voiceID(), string(raw), time.Now().UTC()
	if creating {
		return s.R.DB.Create(ctx, voiceTable, d.ID, &d)
	}
	return s.R.DB.Update(ctx, voiceTable, d.ID, &d)
}

// voiceModel resolves a provider (by id) and one of its models marked for a role.
func (s *Service) voiceModel(ctx context.Context, role, providerID, modelID string) (*llmprovider.Provider, llmprovider.Model, error) {
	all, err := s.List(ctx)
	if err != nil {
		return nil, llmprovider.Model{}, err
	}
	for i := range all {
		p := &all[i]
		if p.ID.String() != providerID {
			continue
		}
		if !p.Enabled || p.APIKey == "" {
			return nil, llmprovider.Model{}, errs.New(errs.CodeUnavailable, "LLM provider "+p.Name+" is disabled or has no API key")
		}
		m, ok := p.Model(modelID)
		if !ok {
			return nil, llmprovider.Model{}, errs.InvalidArgument("model " + modelID + " is not offered by " + p.Name)
		}
		if !m.Has(capabilityOf(role)) {
			return nil, llmprovider.Model{}, errs.InvalidArgument("model " + modelID + " is not marked as a " + capabilityOf(role) + " model (mark it on the Models page)")
		}
		return p, m, nil
	}
	return nil, llmprovider.Model{}, errs.NotFound("LLM provider " + providerID)
}

// voiceView renders the setting for the admin panel: each role as stored, whether it is in effect (and why not), and
// the models to pick from.
func (s *Service) voiceView(ctx context.Context) (map[string]any, error) {
	roles, err := s.VoiceRoles(ctx)
	if err != nil {
		return nil, err
	}
	all, err := s.List(ctx)
	if err != nil {
		return nil, err
	}
	providers := []map[string]any{}
	for i := range all {
		p := &all[i]
		if !p.Enabled || p.APIKey == "" {
			continue
		}
		byRole := map[string]any{}
		for _, role := range llmprovider.VoiceRoles {
			picks := []llmprovider.Model{}
			for _, m := range modelsView(p) {
				if m.Has(capabilityOf(role)) && !m.Disabled {
					picks = append(picks, m)
				}
			}
			byRole[role] = picks
		}
		providers = append(providers, map[string]any{"id": p.ID.String(), "name": p.Name, "kind": p.Kind, "models": byRole})
	}
	out := map[string]any{}
	for _, role := range llmprovider.VoiceRoles {
		r := roles[role]
		active, status := false, "Off: the app uses the device's own."
		if role == llmprovider.VoiceTranscription || role == llmprovider.VoiceLive {
			status = "Off."
		}
		if r.Enabled {
			if _, m, err := s.voiceModel(ctx, role, r.ProviderID, r.ModelID); err != nil {
				status = "On, but unusable (" + err.Error() + ")."
			} else if m.InputPrice <= 0 && m.OutputPrice <= 0 && (m.Units == nil || (m.Units.Character <= 0 && m.Units.Second <= 0)) {
				active, status = true, "On with "+r.ModelID+". It has no price on the Models page, so it is not charged."
			} else {
				active, status = true, "On with "+r.ModelID+", charged at its prices on the Models page."
			}
		}
		out[role] = map[string]any{"enabled": r.Enabled, "provider_id": r.ProviderID, "model_id": r.ModelID, "voice": r.Voice, "active": active, "status": status}
	}
	return map[string]any{"roles": out, "providers": providers}, nil
}

// VoiceActions are the admin actions of the voice models.
func VoiceActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "llm", Name: "llm_voice_get", Summary: "Read the node's voice models (live voice chat)",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := s.requireAdmin(req); err != nil {
					return nil, err
				}
				view, err := s.voiceView(ctx)
				if err != nil {
					return nil, err
				}
				return helper.JSON(view)
			}},
		helper.Action{Namespace: "llm", Name: "llm_voice_set", Summary: "Pick the model for one role of the live voice chat and turn it on or off",
			Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
				if err := s.requireAdmin(req); err != nil {
					return nil, err
				}
				var in VoiceInput
				if err := helper.Decode(req, &in); err != nil {
					return nil, err
				}
				if err := s.SetVoiceRole(ctx, in); err != nil {
					return nil, err
				}
				view, err := s.voiceView(ctx)
				if err != nil {
					return nil, err
				}
				return helper.JSON(view)
			}},
	}
}

// VoiceActive says which roles are in effect (for the app: it asks before it plays anything).
func (s *Service) VoiceActive(ctx context.Context) (map[string]bool, error) {
	roles, err := s.VoiceRoles(ctx)
	if err != nil {
		return nil, err
	}
	out := map[string]bool{}
	for role, r := range roles {
		if !r.Enabled {
			continue
		}
		_, _, err := s.voiceModel(ctx, role, r.ProviderID, r.ModelID)
		out[role] = err == nil
	}
	return out, nil
}

// Speech is spoken audio (see vmm.Speech).
type Speech = vmm.Speech

var speechClient = &http.Client{Timeout: 60 * time.Second}

// Speak turns text into audio with the node's speech model (Admin → AI → Voice). A Google model is asked through its
// own generateContent API (it answers raw PCM, made a WAV here); any other provider through the OpenAI-compatible
// audio/speech endpoint (MP3).
func (s *Service) Speak(ctx context.Context, text string) (*Speech, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil, errs.InvalidArgument("nothing to say")
	}
	roles, err := s.VoiceRoles(ctx)
	if err != nil {
		return nil, err
	}
	r := roles[llmprovider.VoiceSpeech]
	if !r.Enabled {
		return nil, errs.New(errs.CodeUnavailable, "no speech model is set")
	}
	p, m, err := s.voiceModel(ctx, llmprovider.VoiceSpeech, r.ProviderID, r.ModelID)
	if err != nil {
		return nil, errs.New(errs.CodeUnavailable, "the speech model is unavailable: "+err.Error())
	}
	var (
		audio     []byte
		mime      string
		in, out   int64
		callError error
	)
	if usesGeminiSpeech(p) {
		audio, mime, in, out, callError = geminiSpeech(ctx, p, m.ID, r.Voice, text)
	} else {
		audio, mime, in, out, callError = openAISpeech(ctx, p, m.ID, r.Voice, text)
	}
	if callError != nil {
		return nil, callError
	}
	price := speechCost(m, text, in, out)
	return &Speech{Audio: audio, Mime: mime, Model: p.Name + " / " + m.ID, ProviderID: p.ID.String(), ModelID: m.ID, TokensIn: in, TokensOut: out, Price: price}, nil
}

// speechCost prices one piece of speech in ledger units, rounded up: the tokens the provider reported at the model's
// token prices (a Gemini speech model bills the text in and the audio out that way), plus the characters said at its
// price per character (a model such as OpenAI's tts-1). A model priced one way or the other, or both, works.
func speechCost(m llmprovider.Model, text string, tokensIn, tokensOut int64) float64 {
	c := (float64(tokensIn)*m.InputPrice + float64(tokensOut)*m.OutputPrice) / 1e6
	if m.Units != nil {
		c += float64(utf8.RuneCountInString(text)) * m.Units.Character
	}
	if c <= 0 {
		return 0
	}
	return math.Ceil(c - 1e-9)
}

func usesGeminiSpeech(p *llmprovider.Provider) bool {
	return p.Kind == llmprovider.KindVertex || p.Kind == llmprovider.KindGemini || strings.Contains(p.BaseURL, "googleapis.com")
}

func setSpeechAuth(req *http.Request, p *llmprovider.Provider, google bool) {
	if p.APIKey == "" {
		return
	}
	switch {
	case google && !strings.HasPrefix(p.APIKey, "ya29."):
		req.Header.Set("X-Goog-Api-Key", p.APIKey)
	default:
		req.Header.Set("Authorization", "Bearer "+p.APIKey)
	}
}

// geminiSpeech asks a Gemini text-to-speech model for audio. The voice is one of its prebuilt names ("Kore" when none).
func geminiSpeech(ctx context.Context, p *llmprovider.Provider, model, voice, text string) ([]byte, string, int64, int64, error) {
	if voice == "" {
		voice = "Kore"
	}
	raw, _ := json.Marshal(map[string]any{
		"contents": []any{map[string]any{"role": "user", "parts": []any{map[string]any{"text": text}}}},
		"generationConfig": map[string]any{
			"responseModalities": []string{"AUDIO"},
			"speechConfig":       map[string]any{"voiceConfig": map[string]any{"prebuiltVoiceConfig": map[string]any{"voiceName": voice}}},
		},
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, geminiImageURL(imageBaseURL(ctx, p), model), bytes.NewReader(raw))
	if err != nil {
		return nil, "", 0, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	setSpeechAuth(req, p, true)
	resp, err := speechClient.Do(req)
	if err != nil {
		return nil, "", 0, 0, errs.Wrap(errs.CodeUnavailable, err, "the speech model could not be reached")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return nil, "", 0, 0, errs.Wrap(errs.CodeUnavailable, err, "the speech model's answer was cut short")
	}
	if resp.StatusCode >= 300 {
		return nil, "", 0, 0, errs.New(errs.CodeUnavailable, fmt.Sprintf("the speech model refused the request (%d): %s", resp.StatusCode, clip(strings.Join(strings.Fields(string(data)), " "), 300)))
	}
	var out struct {
		Candidates []struct {
			Content struct {
				Parts []struct {
					InlineData *struct {
						MimeType string `json:"mimeType"`
						Data     string `json:"data"`
					} `json:"inlineData"`
					InlineDataSnake *struct {
						MimeType string `json:"mime_type"`
						Data     string `json:"data"`
					} `json:"inline_data"`
				} `json:"parts"`
			} `json:"content"`
		} `json:"candidates"`
		UsageMetadata struct {
			PromptTokenCount     int64 `json:"promptTokenCount"`
			CandidatesTokenCount int64 `json:"candidatesTokenCount"`
		} `json:"usageMetadata"`
	}
	if json.Unmarshal(data, &out) != nil {
		return nil, "", 0, 0, errs.New(errs.CodeUnavailable, "the speech model answered in a form that could not be read")
	}
	for _, c := range out.Candidates {
		for _, part := range c.Content.Parts {
			d := part.InlineData
			mime := ""
			if d != nil {
				mime = d.MimeType
			} else if part.InlineDataSnake != nil {
				d, mime = &struct {
					MimeType string `json:"mimeType"`
					Data     string `json:"data"`
				}{Data: part.InlineDataSnake.Data}, part.InlineDataSnake.MimeType
			}
			if d == nil || d.Data == "" {
				continue
			}
			pcm, err := base64.StdEncoding.DecodeString(d.Data)
			if err != nil {
				return nil, "", 0, 0, errs.Wrap(errs.CodeUnavailable, err, "decode speech")
			}
			return playableAudio(pcm, mime), "audio/wav", out.UsageMetadata.PromptTokenCount, out.UsageMetadata.CandidatesTokenCount, nil
		}
	}
	return nil, "", 0, 0, errs.New(errs.CodeUnavailable, "the speech model returned no audio")
}

// openAISpeech asks an OpenAI-compatible provider's audio/speech endpoint for MP3. It reports no tokens, so the
// text's length stands in for the tokens in (and the audio is not counted).
func openAISpeech(ctx context.Context, p *llmprovider.Provider, model, voice, text string) ([]byte, string, int64, int64, error) {
	// Empty voice lets local sidecars (Kokoro) use their own default. Only the
	// public OpenAI TTS voices need a name; "alloy" is wrong for Kokoro/Piper.
	payload := map[string]any{"model": model, "input": text, "response_format": "mp3"}
	if voice != "" {
		payload["voice"] = voice
	} else if !strings.Contains(strings.ToLower(p.BaseURL+p.Name+model), "kokoro") &&
		!strings.Contains(strings.ToLower(p.BaseURL), "voice") &&
		!strings.Contains(strings.ToLower(p.BaseURL), "8091") {
		payload["voice"] = "alloy"
	}
	raw, _ := json.Marshal(payload)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(imageBaseURL(ctx, p), "/")+"/audio/speech", bytes.NewReader(raw))
	if err != nil {
		return nil, "", 0, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	setSpeechAuth(req, p, false)
	resp, err := speechClient.Do(req)
	if err != nil {
		return nil, "", 0, 0, errs.Wrap(errs.CodeUnavailable, err, "the speech model could not be reached")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return nil, "", 0, 0, errs.Wrap(errs.CodeUnavailable, err, "the speech model's answer was cut short")
	}
	if resp.StatusCode >= 300 {
		return nil, "", 0, 0, errs.New(errs.CodeUnavailable, fmt.Sprintf("the speech model refused the request (%d): %s", resp.StatusCode, clip(strings.Join(strings.Fields(string(data)), " "), 300)))
	}
	return data, "audio/mpeg", int64(len(text)) / 4, 0, nil
}

// playableAudio is what a Gemini speech model returned, as a WAV file: Gemini 3.8 models answer with a WAV already, earlier
// ones with raw 16-bit PCM (whose mime type says its sample rate), which is wrapped here.
func playableAudio(data []byte, mime string) []byte {
	if bytes.HasPrefix(data, []byte("RIFF")) && len(data) > 12 && string(data[8:12]) == "WAVE" {
		return data
	}
	return pcmWAV(data, pcmRate(mime))
}

// pcmRate reads the sample rate out of a mime type like "audio/L16;codec=pcm;rate=24000" (24000 when it has none).
func pcmRate(mime string) int {
	for _, part := range strings.Split(mime, ";") {
		if k, v, ok := strings.Cut(strings.TrimSpace(part), "="); ok && strings.EqualFold(k, "rate") {
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				return n
			}
		}
	}
	return 24000
}

// pcmWAV wraps 16-bit mono little-endian PCM in a WAV header, so a browser or a phone can play it.
func pcmWAV(pcm []byte, rate int) []byte {
	var b bytes.Buffer
	b.WriteString("RIFF")
	_ = binary.Write(&b, binary.LittleEndian, uint32(36+len(pcm)))
	b.WriteString("WAVEfmt ")
	_ = binary.Write(&b, binary.LittleEndian, uint32(16))
	_ = binary.Write(&b, binary.LittleEndian, uint16(1)) // PCM
	_ = binary.Write(&b, binary.LittleEndian, uint16(1)) // mono
	_ = binary.Write(&b, binary.LittleEndian, uint32(rate))
	_ = binary.Write(&b, binary.LittleEndian, uint32(rate*2))
	_ = binary.Write(&b, binary.LittleEndian, uint16(2))
	_ = binary.Write(&b, binary.LittleEndian, uint16(16))
	b.WriteString("data")
	_ = binary.Write(&b, binary.LittleEndian, uint32(len(pcm)))
	b.Write(pcm)
	return b.Bytes()
}
