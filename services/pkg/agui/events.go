// Package agui implements AG-UI 1.0 event types and Aseman surface CUSTOM events.
package agui

// EventType is an AG-UI 1.0 event type string.
type EventType = string

// AG-UI 1.0 event types (and basic REASONING / SUBAGENT stubs).
const (
	EventRunStarted              EventType = "RUN_STARTED"
	EventRunFinished             EventType = "RUN_FINISHED"
	EventRunError                EventType = "RUN_ERROR"
	EventStepStarted             EventType = "STEP_STARTED"
	EventStepFinished            EventType = "STEP_FINISHED"
	EventTextMessageStart        EventType = "TEXT_MESSAGE_START"
	EventTextMessageContent      EventType = "TEXT_MESSAGE_CONTENT"
	EventTextMessageEnd          EventType = "TEXT_MESSAGE_END"
	EventTextMessageChunk        EventType = "TEXT_MESSAGE_CHUNK"
	EventToolCallStart           EventType = "TOOL_CALL_START"
	EventToolCallArgs            EventType = "TOOL_CALL_ARGS"
	EventToolCallEnd             EventType = "TOOL_CALL_END"
	EventToolCallChunk           EventType = "TOOL_CALL_CHUNK"
	EventToolCallResult          EventType = "TOOL_CALL_RESULT"
	EventStateSnapshot           EventType = "STATE_SNAPSHOT"
	EventStateDelta              EventType = "STATE_DELTA"
	EventMessagesSnapshot        EventType = "MESSAGES_SNAPSHOT"
	EventActivitySnapshot        EventType = "ACTIVITY_SNAPSHOT"
	EventActivityDelta           EventType = "ACTIVITY_DELTA"
	EventRaw                     EventType = "RAW"
	EventCustom                  EventType = "CUSTOM"
	EventReasoningStart          EventType = "REASONING_START"
	EventReasoningMessageStart   EventType = "REASONING_MESSAGE_START"
	EventReasoningMessageContent EventType = "REASONING_MESSAGE_CONTENT"
	EventReasoningMessageEnd     EventType = "REASONING_MESSAGE_END"
	EventReasoningMessageChunk   EventType = "REASONING_MESSAGE_CHUNK"
	EventReasoningEnd            EventType = "REASONING_END"
	EventReasoningEncryptedValue EventType = "REASONING_ENCRYPTED_VALUE"
	EventSubagentStarted         EventType = "SUBAGENT_STARTED"
	EventSubagentFinished        EventType = "SUBAGENT_FINISHED"
	EventSubagentError           EventType = "SUBAGENT_ERROR"
)

// Event is a JSON-friendly AG-UI event. Common and type-specific fields share
// one struct; unused fields are omitted. Extra payload may live in Fields.
type Event struct {
	Type      string         `json:"type"`
	Timestamp *int64         `json:"timestamp,omitempty"`
	RawEvent  any            `json:"rawEvent,omitempty"`
	Metadata  map[string]any `json:"metadata,omitempty"`

	// Lifecycle
	ThreadID    string `json:"threadId,omitempty"`
	RunID       string `json:"runId,omitempty"`
	ParentRunID string `json:"parentRunId,omitempty"`
	Message     string `json:"message,omitempty"`
	Code        string `json:"code,omitempty"`
	StepName    string `json:"stepName,omitempty"`

	// Messages / tools / activity
	MessageID  string `json:"messageId,omitempty"`
	Role       string `json:"role,omitempty"`
	Delta      string `json:"delta,omitempty"`
	ToolCallID string `json:"toolCallId,omitempty"`
	ToolName   string `json:"toolName,omitempty"`
	Args       string `json:"args,omitempty"`
	Content    any    `json:"content,omitempty"`
	Result     any    `json:"result,omitempty"`

	// State
	Snapshot any   `json:"snapshot,omitempty"`
	DeltaOps []any `json:"deltaOps,omitempty"` // STATE_DELTA patch ops (JSON Patch-like)

	// Activity
	ActivityType string `json:"activityType,omitempty"`

	// Custom / raw
	Name  string `json:"name,omitempty"`
	Value any    `json:"value,omitempty"`
	Event any    `json:"event,omitempty"` // RAW

	// Catch-all for forward-compatible fields.
	Fields map[string]any `json:"-"`
}

// NewCustom builds a CUSTOM event.
func NewCustom(name string, value any) Event {
	return Event{Type: EventCustom, Name: name, Value: value}
}

// NewStateSnapshot builds a STATE_SNAPSHOT event.
func NewStateSnapshot(snapshot any) Event {
	return Event{Type: EventStateSnapshot, Snapshot: snapshot}
}

// NewStateDelta builds a STATE_DELTA event from patch operations.
func NewStateDelta(delta []any) Event {
	return Event{Type: EventStateDelta, DeltaOps: delta}
}

// NewRunStarted builds a RUN_STARTED event.
func NewRunStarted(threadID, runID string) Event {
	return Event{Type: EventRunStarted, ThreadID: threadID, RunID: runID}
}

// NewRunFinished builds a RUN_FINISHED event.
func NewRunFinished(threadID, runID string) Event {
	return Event{Type: EventRunFinished, ThreadID: threadID, RunID: runID}
}

// NewRunError builds a RUN_ERROR event.
func NewRunError(message string) Event {
	return Event{Type: EventRunError, Message: message}
}

// NewActivitySnapshot builds an ACTIVITY_SNAPSHOT event.
func NewActivitySnapshot(messageID, activityType string, content any) Event {
	return Event{
		Type:         EventActivitySnapshot,
		MessageID:    messageID,
		ActivityType: activityType,
		Content:      content,
	}
}
