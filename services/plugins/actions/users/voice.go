package users

import (
	"context"
	"encoding/base64"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// The node's voice models in a live voice chat (Admin → AI → Voice): which roles are on, and speech for the app to play.
// A role that is off keeps the device's own, so the app asks first (users.voice_config).

const (
	speakMaxChars = 900
	speakPerMin   = 90
)

// voiceActive says which voice roles the admin has turned on and that work.
func (s *Service) voiceActive(ctx context.Context) map[string]bool {
	if s.voiceActiveFn != nil {
		return s.voiceActiveFn(ctx)
	}
	out := map[string]bool{}
	if err := bridge.Invoke(ctx, s.K, "llm", "VoiceActive", []any{ctx}, &out); err != nil {
		return map[string]bool{}
	}
	return out
}

func (s *Service) speak(ctx context.Context, me identity.ID, text string) (*vmm.Speech, error) {
	if s.speakFn != nil {
		return s.speakFn(ctx, me, text)
	}
	rec, err := s.assistant(ctx)
	if err != nil {
		return nil, err
	}
	var out *vmm.Speech
	err = bridge.Invoke(ctx, s.K, "bots", "ChatSpeak", []any{ctx, me, rec.ID, text}, &out)
	return out, err
}

func (s *Service) transcribe(ctx context.Context, me identity.ID, audio []byte, mime string) (*vmm.Transcription, error) {
	if s.transcribeFn != nil {
		return s.transcribeFn(ctx, me, audio, mime)
	}
	rec, err := s.assistant(ctx)
	if err != nil {
		return nil, err
	}
	var out *vmm.Transcription
	err = bridge.Invoke(ctx, s.K, "bots", "ChatTranscribe", []any{ctx, me, rec.ID, audio, mime}, &out)
	return out, err
}

func (s *Service) voiceReply(ctx context.Context, me identity.ID, text string) (string, error) {
	if s.voiceAnswerFn != nil {
		return s.voiceAnswerFn(ctx, me, text)
	}
	return s.answerVoiceNote(ctx, me, text)
}

var (
	speakMu    sync.Mutex
	speakCalls = map[identity.ID][]time.Time{}
)

// speakAllowed keeps one person from running up the speech model: speakPerMin calls a minute.
func speakAllowed(me identity.ID, now time.Time) bool {
	speakMu.Lock()
	defer speakMu.Unlock()
	recent := speakCalls[me][:0]
	for _, t := range speakCalls[me] {
		if now.Sub(t) < time.Minute {
			recent = append(recent, t)
		}
	}
	if len(recent) >= speakPerMin {
		speakCalls[me] = recent
		return false
	}
	speakCalls[me] = append(recent, now)
	return true
}

// voiceConfigAction users.voice_config: which voice roles the node serves ({speech, transcription, live}: true when on).
func voiceConfigAction(s *Service) api.Action {
	return helper.Action{Namespace: "users", Name: "voice_config", Summary: "Which voice models the node uses in a live voice chat",
		Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireUser(req); err != nil {
				return nil, err
			}
			active := s.voiceActive(ctx)
			return helper.JSON(map[string]any{"speech": active["speech"], "transcription": active["transcription"], "live": active["live"]})
		}}
}

// voiceSpeakAction users.voice_speak: text spoken by the node's speech model, as audio the app plays. Billed to the person.
func voiceSpeakAction(s *Service) api.Action {
	return helper.Action{Namespace: "users", Name: "voice_speak", Summary: "Have the node's speech model say a piece of text aloud",
		Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireUser(req); err != nil {
				return nil, err
			}
			var in struct {
				Text string `json:"text"`
			}
			if err := helper.Decode(req, &in); err != nil {
				return nil, err
			}
			text := clip(strings.TrimSpace(in.Text), speakMaxChars)
			if text == "" {
				return nil, errs.InvalidArgument("text required")
			}
			if !s.voiceActive(ctx)["speech"] {
				return nil, errs.New(errs.CodeUnavailable, "no speech model is set")
			}
			if !speakAllowed(req.Caller.ID, time.Now()) {
				return nil, errs.New(errs.CodeUnavailable, "too many spoken answers in a minute")
			}
			speech, err := s.speak(ctx, req.Caller.ID, text)
			if err != nil {
				return nil, err
			}
			return helper.JSON(map[string]any{"audio": base64.StdEncoding.EncodeToString(speech.Audio), "mime": speech.Mime})
		}}
}

const (
	voiceTurnAudioMax = 3 << 20 // ~3 MiB WAV (~90s @ 16 kHz mono)
	voiceTurnPerMin   = 30
)

var (
	voiceTurnMu    sync.Mutex
	voiceTurnCalls = map[identity.ID][]time.Time{}
)

func voiceTurnAllowed(me identity.ID, now time.Time) bool {
	voiceTurnMu.Lock()
	defer voiceTurnMu.Unlock()
	recent := voiceTurnCalls[me][:0]
	for _, t := range voiceTurnCalls[me] {
		if now.Sub(t) < time.Minute {
			recent = append(recent, t)
		}
	}
	if len(recent) >= voiceTurnPerMin {
		voiceTurnCalls[me] = recent
		return false
	}
	voiceTurnCalls[me] = append(recent, now)
	return true
}

// voiceTurnAction users.voice_turn: one spoken turn — STT → Aseman brain → TTS.
// The app streams mic PCM as WAV; the reply audio is played back.
func voiceTurnAction(s *Service) api.Action {
	return helper.Action{Namespace: "users", Name: "voice_turn", Summary: "One live voice turn: hear, answer as Aseman, speak back",
		Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			if err := helper.RequireUser(req); err != nil {
				return nil, err
			}
			var in struct {
				Audio string `json:"audio"`
				Mime  string `json:"mime"`
			}
			if err := helper.Decode(req, &in); err != nil {
				return nil, err
			}
			raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(in.Audio))
			if err != nil || len(raw) == 0 {
				return nil, errs.InvalidArgument("audio required")
			}
			if len(raw) > voiceTurnAudioMax {
				return nil, errs.InvalidArgument("audio too long")
			}
			mime := strings.TrimSpace(in.Mime)
			if mime == "" {
				mime = "audio/wav"
			}
			active := s.voiceActive(ctx)
			if !active["transcription"] {
				return nil, errs.New(errs.CodeUnavailable, "no transcription model is set")
			}
			if !active["speech"] {
				return nil, errs.New(errs.CodeUnavailable, "no speech model is set")
			}
			if !voiceTurnAllowed(req.Caller.ID, time.Now()) {
				return nil, errs.New(errs.CodeUnavailable, "too many voice turns in a minute")
			}
			heard, err := s.transcribe(ctx, req.Caller.ID, raw, mime)
			if err != nil {
				return nil, err
			}
			text := strings.TrimSpace(heard.Text)
			if text == "" {
				return nil, errs.New(errs.CodeUnavailable, "nothing heard")
			}
			reply, err := s.voiceReply(ctx, req.Caller.ID, text)
			if err != nil {
				return nil, err
			}
			if reply == "" {
				reply = "Got it."
			}
			spoken := clip(reply, speakMaxChars)
			speech, err := s.speak(ctx, req.Caller.ID, spoken)
			if err != nil {
				// Still return the text turn so the sheet can show it.
				return helper.JSON(map[string]any{
					"heard": text, "reply": reply, "audio": "", "mime": "",
					"speak_error": err.Error(),
				})
			}
			return helper.JSON(map[string]any{
				"heard": text,
				"reply": reply,
				"audio": base64.StdEncoding.EncodeToString(speech.Audio),
				"mime":  speech.Mime,
			})
		}}
}
