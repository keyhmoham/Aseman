package developer

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
)

// Dictate writes down what a person said (the chat's voice button), on the
// node's transcription model, billed to the person's own wallet like the
// rest of their model use (their personal organization). The model is
// ASEMAN_TRANSCRIPTION_MODEL, or the catalog's first transcription model.
func (s *Service) Dictate(ctx context.Context, account identity.ID, audio, mediaType string) (string, error) {
	if strings.TrimSpace(audio) == "" {
		return "", errs.InvalidArgument("no audio")
	}
	if base64.StdEncoding.DecodedLen(len(audio)) > maxAudioBytes {
		return "", errs.InvalidArgument("the recording is longer than dictation takes")
	}
	model := strings.TrimSpace(os.Getenv("ASEMAN_TRANSCRIPTION_MODEL"))
	if model == "" {
		catalog, err := s.Catalog(ctx)
		if err != nil {
			return "", err
		}
		for _, m := range catalog {
			if m.Type == TypeTranscription {
				model = m.ID
				break
			}
		}
	}
	if model == "" {
		return "", errs.New(errs.CodeUnavailable, "no speech-to-text model on this node: an administrator imports one (Admin → Models)")
	}
	if mediaType == "" {
		mediaType = "audio/webm"
	}
	res := s.Execute(ctx, Call{Org: account, KeyID: "dictation", KeyName: "Dictation", Type: TypeTranscription, Model: model,
		Body: map[string]any{"audio": audio, "media_type": mediaType}})
	if res == nil {
		return "", errs.New(errs.CodeUnavailable, "dictation failed")
	}
	var out struct {
		Text  string `json:"text"`
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal(res.Body, &out)
	if res.Status >= 300 {
		msg := out.Error.Message
		if msg == "" {
			msg = "dictation failed"
		}
		return "", errs.New(errs.CodeUnavailable, msg)
	}
	return strings.TrimSpace(out.Text), nil
}

func dictateAction(s *Service) api.Action {
	return helper.Action{Namespace: "developer", Name: "dictate", Summary: "Write down a voice recording (base64 audio) as text, billed to me", Handler: func(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
		if err := helper.RequireUser(req); err != nil {
			return nil, err
		}
		var in struct {
			Audio     string `json:"audio"`
			MediaType string `json:"media_type"`
		}
		if err := helper.Decode(req, &in); err != nil {
			return nil, err
		}
		text, err := s.Dictate(ctx, req.Caller.ID, in.Audio, in.MediaType)
		if err != nil {
			return nil, err
		}
		return helper.JSON(map[string]any{"text": text})
	}}
}
