// Package message defines federated messages exchanged in rooms, directly
// between accounts, or as request/response packets between users and bots.
package message

import (
	"encoding/json"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
)

// Direct is a direct message between two accounts (no space).
type Direct struct {
	entity.Entity
	From   identity.ID `db:"from_id" json:"from_id"`
	To     identity.ID `db:"to_id" json:"to_id"`
	Body   string      `db:"body" json:"body"`
	SentAt time.Time   `db:"sent_at" json:"sent_at"`
}

// PacketKind classifies the packet's semantics.
type PacketKind string

const (
	// PacketMessage is a fire-and-forget packet between a user and a user/bot.
	PacketMessage PacketKind = "message"
	// PacketAsk is a request sent to a user or bot that expects a response.
	PacketAsk PacketKind = "ask"
	// PacketResponse is the answer to a PacketAsk, correlated via CorrelationID.
	PacketResponse PacketKind = "response"
)

// PacketStatus tracks the lifecycle of an ask/response exchange.
type PacketStatus string

const (
	// StatusSent marks a delivered fire-and-forget packet.
	StatusSent PacketStatus = "sent"
	// StatusRequested marks an ask awaiting its response.
	StatusRequested PacketStatus = "requested"
	// StatusAnswered marks an ask that received a response.
	StatusAnswered PacketStatus = "answered"
	// StatusFailed marks an ask the recipient could not answer.
	StatusFailed PacketStatus = "failed"
)

// Packet is the universal transport envelope between accounts (users and bots).
// It powers both fire-and-forget messaging (message.send) and the
// request/response protocol (message.ask / message.respond) used by chat
// agents, app backends and bot-to-bot orchestration.
type Packet struct {
	entity.Entity
	From identity.ID `db:"from_id" json:"from_id"` // sender account (user or bot)
	To   identity.ID `db:"to_id" json:"to_id"`     // receiver account (user or bot)

	// Kind is message, ask or response.
	Kind PacketKind `db:"kind" json:"kind"`

	// Status is sent, requested, answered or failed.
	Status PacketStatus `db:"status" json:"status"`

	// Body is the human-readable content of the packet.
	Body string `db:"body" json:"body"`

	// Payload is an optional structured, JSON-encoded payload. App
	// frontends carry the opcode/args of their backend calls in here.
	Payload string `db:"payload" json:"payload,omitempty"`

	// CorrelationID references the ask packet this packet answers (responses)
	// or, on a response, the ask it belongs to. Zero for fire-and-forget.
	CorrelationID identity.ID `db:"correlation_id" json:"correlation_id,omitempty"`

	// RepliedAt is set when an ask receives its response.
	RepliedAt time.Time `db:"replied_at" json:"replied_at,omitempty"`

	// ReceivedAt is the moment the recipient became aware of the packet.
	ReceivedAt time.Time `db:"received_at" json:"received_at,omitempty"`
}

// Message kinds: KindMessage is a normal conversation message (users, agent
// replies, aseman's final answers); KindLog is agentic-flow content (plans,
// dispatches, tool/sandbox outputs) that the client renders as a collapsible
// log section instead of a chat bubble. KindTool is a tool's reply to a
// command a person ran in the room (body: JSON {command, result}). Tools'
// interfaces never go into the chat: they open on the room's desk.
const (
	KindMessage = "message"
	KindLog     = "log"
	KindTool    = "tool"
)

// Message is a message inside a room of a space.
type Message struct {
	entity.Entity
	SpaceID  identity.ID `db:"space_id" json:"space_id"`
	RoomID   identity.ID `db:"room_id" json:"room_id"`
	SenderID identity.ID `db:"sender_id" json:"sender_id"`
	Body     string      `db:"body" json:"body"`
	// Kind distinguishes conversation messages from agentic-flow logs
	// (see KindMessage / KindLog above). Empty means a normal message.
	Kind string `db:"kind" json:"kind"`
	// Mentions is a JSON-encoded []string of explicitly referenced member ids
	// (users and agents). Mentioned agents are triggered to respond; the
	// message is still delivered as conversation history to the space's other
	// agents. Stored explicitly so the protocol never has to parse "@" out of
	// raw body text.
	Mentions string `db:"mentions" json:"mentions,omitempty"`
	// AttachmentIDs is a JSON-encoded []string of file ids attached to this
	// message (photos, gifs, audio, voice, video, documents, ...). The client
	// uploads the file first (spaces.file_upload) and references it here so a
	// message can carry several attachments.
	AttachmentIDs string `db:"attachment_ids" json:"attachment_ids,omitempty"`
	// ReplyTo is the message this one answers. An agent's reply to the message
	// that triggered it carries it, which is how a delegating agent (or a
	// person) finds the answer to a request in the room.
	ReplyTo  string    `db:"reply_to" json:"reply_to,omitempty"`
	EditedAt time.Time `db:"edited_at" json:"edited_at,omitempty"`
}

// ParseMentions decodes the mentions JSON column into the mentioned member ids.
func (m *Message) ParseMentions() []string {
	if m.Mentions == "" {
		return nil
	}
	var out []string
	if err := json.Unmarshal([]byte(m.Mentions), &out); err != nil {
		return nil
	}
	return out
}

// SetMentions encodes the mentions list into the JSON column (always a valid
// JSON array, so empty mentions store as `[]`).
func (m *Message) SetMentions(ids []string) {
	if len(ids) == 0 {
		m.Mentions = "[]"
		return
	}
	b, err := json.Marshal(ids)
	if err != nil {
		m.Mentions = "[]"
		return
	}
	m.Mentions = string(b)
}

// ParseAttachments decodes the attachment_ids JSON column into the file ids.
func (m *Message) ParseAttachments() []string {
	if m.AttachmentIDs == "" {
		return nil
	}
	var out []string
	if err := json.Unmarshal([]byte(m.AttachmentIDs), &out); err != nil {
		return nil
	}
	return out
}

// SetAttachments encodes the file id list into the JSON column (always a
// valid JSON array, so no attachments store as `[]`).
func (m *Message) SetAttachments(ids []string) {
	if len(ids) == 0 {
		m.AttachmentIDs = "[]"
		return
	}
	b, err := json.Marshal(ids)
	if err != nil {
		m.AttachmentIDs = "[]"
		return
	}
	m.AttachmentIDs = string(b)
}
