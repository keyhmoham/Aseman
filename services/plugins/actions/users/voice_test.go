package users

import (
	"context"
	"encoding/base64"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func TestSpeechIsServedOnlyWhenTheNodeHasASpeechModel(t *testing.T) {
	f := dmHarness(t)
	on := false
	f.s.voiceActiveFn = func(context.Context) map[string]bool { return map[string]bool{"speech": on} }
	var said []string
	f.s.speakFn = func(_ context.Context, _ identity.ID, text string) (*vmm.Speech, error) {
		said = append(said, text)
		return &vmm.Speech{Audio: []byte("RIFFwav"), Mime: "audio/wav"}, nil
	}
	if f.must("voice_config", f.alice, nil)["speech"] != false {
		t.Fatal("speech reported on with no model")
	}
	if _, err := f.call("voice_speak", f.alice, map[string]any{"text": "hello"}); errs.CodeOf(err) != errs.CodeUnavailable || len(said) != 0 {
		t.Fatalf("spoke with no speech model: %v %v", err, said)
	}
	on = true
	if f.must("voice_config", f.alice, nil)["speech"] != true {
		t.Fatal("speech not reported on")
	}
	out := f.must("voice_speak", f.alice, map[string]any{"text": "  Hello there.  "})
	raw, _ := base64.StdEncoding.DecodeString(out["audio"].(string))
	if string(raw) != "RIFFwav" || out["mime"] != "audio/wav" || len(said) != 1 || said[0] != "Hello there." {
		t.Fatalf("%v %v", out, said)
	}
	if _, err := f.call("voice_speak", f.alice, map[string]any{"text": "   "}); err == nil {
		t.Fatal("empty text was spoken")
	}
}

func TestSpeechIsLimitedPerPerson(t *testing.T) {
	me := mustID(t, "00000000000000010000000000000071")
	now := time.Now()
	for i := 0; i < speakPerMin; i++ {
		if !speakAllowed(me, now) {
			t.Fatalf("refused call %d", i)
		}
	}
	if speakAllowed(me, now) {
		t.Fatal("no limit")
	}
	if !speakAllowed(me, now.Add(61*time.Second)) {
		t.Fatal("still refused a minute later")
	}
}

func TestVoiceTurnRunsSTTBrainTTS(t *testing.T) {
	f := dmHarness(t)
	f.s.voiceActiveFn = func(context.Context) map[string]bool {
		return map[string]bool{"speech": true, "transcription": true}
	}
	f.s.transcribeFn = func(_ context.Context, _ identity.ID, audio []byte, mime string) (*vmm.Transcription, error) {
		if len(audio) == 0 || mime == "" {
			t.Fatalf("bad audio %d %q", len(audio), mime)
		}
		return &vmm.Transcription{Text: "What is the weather?", Seconds: 1.2}, nil
	}
	f.s.voiceAnswerFn = func(_ context.Context, _ identity.ID, text string) (string, error) {
		if text != "What is the weather?" {
			t.Fatalf("brain got %q", text)
		}
		return "It looks sunny.", nil
	}
	f.s.speakFn = func(_ context.Context, _ identity.ID, text string) (*vmm.Speech, error) {
		if text != "It looks sunny." {
			t.Fatalf("tts got %q", text)
		}
		return &vmm.Speech{Audio: []byte("spoken"), Mime: "audio/mpeg"}, nil
	}
	out := f.must("voice_turn", f.alice, map[string]any{
		"audio": base64.StdEncoding.EncodeToString([]byte("fake-wav")),
		"mime":  "audio/wav",
	})
	raw, _ := base64.StdEncoding.DecodeString(out["audio"].(string))
	if out["heard"] != "What is the weather?" || out["reply"] != "It looks sunny." ||
		string(raw) != "spoken" || out["mime"] != "audio/mpeg" {
		t.Fatalf("%v", out)
	}
}

func TestVoiceTurnNeedsBothModels(t *testing.T) {
	f := dmHarness(t)
	f.s.voiceActiveFn = func(context.Context) map[string]bool {
		return map[string]bool{"speech": true, "transcription": false}
	}
	if _, err := f.call("voice_turn", f.alice, map[string]any{
		"audio": base64.StdEncoding.EncodeToString([]byte("x")),
		"mime":  "audio/wav",
	}); errs.CodeOf(err) != errs.CodeUnavailable {
		t.Fatalf("expected unavailable, got %v", err)
	}
}
