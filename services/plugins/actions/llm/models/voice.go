package llmprovider

import (
	"time"

	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Voice roles: what a model is used for in a live voice chat with Aseman. Each has its own model, so they can be
// different models or, later, one.
const (
	// VoiceSpeech turns the answer into audio (text to speech).
	VoiceSpeech = "speech"
	// VoiceTranscription turns what the person says into text.
	VoiceTranscription = "transcription"
	// VoiceLive is one model that hears and answers in voice, over one connection.
	VoiceLive = "live"
)

// VoiceRoles lists the roles a voice setting has.
var VoiceRoles = []string{VoiceSpeech, VoiceTranscription, VoiceLive}

// VoiceRole is the model chosen for one role (Admin → AI → Voice).
type VoiceRole struct {
	Enabled    bool   `json:"enabled"`
	ProviderID string `json:"provider_id"`
	ModelID    string `json:"model_id"`
	// Voice is the name of the voice it speaks with (a speech or live model).
	Voice string `json:"voice,omitempty"`
}

// VoiceSetting is the node's voice models, chosen by the admin: a role with no model keeps what the app does
// without one (the device's own speech recognition and voices). Roles is a JSON object of role → VoiceRole.
type VoiceSetting struct {
	ID        string    `db:"id" json:"-"`
	Roles     string    `db:"roles" json:"-"`
	UpdatedAt time.Time `db:"updated_at" json:"updated_at"`
}

func llmVoice() database.Model {
	return database.Model{
		Name:  "llm_voice",
		Table: "llm_voice",
		Fields: []database.Field{
			f("id", database.KindString), f("roles", database.KindString), f("updated_at", database.KindTime),
		},
	}
}
