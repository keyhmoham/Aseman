package agui

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

// EncodeSSE encodes events as an AG-UI SSE stream (one JSON object per data line).
func EncodeSSE(events []Event) string {
	var b strings.Builder
	for _, ev := range events {
		raw, err := json.Marshal(eventToMap(ev))
		if err != nil {
			continue
		}
		b.WriteString("data: ")
		b.Write(raw)
		b.WriteByte('\n')
		b.WriteByte('\n')
	}
	return b.String()
}

// DecodeEvent decodes one AG-UI event JSON object.
func DecodeEvent(raw []byte) (Event, error) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return Event{}, fmt.Errorf("empty event")
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return Event{}, err
	}
	return mapToEvent(m), nil
}

// EventsToMaps converts events to JSON-friendly maps (for storage / tooling).
func EventsToMaps(events []Event) []map[string]any {
	out := make([]map[string]any, len(events))
	for i, ev := range events {
		out[i] = eventToMap(ev)
	}
	return out
}

func eventToMap(ev Event) map[string]any {
	m := map[string]any{"type": ev.Type}
	put := func(k string, v any) {
		if v == nil {
			return
		}
		switch x := v.(type) {
		case string:
			if x == "" {
				return
			}
		case []any:
			if len(x) == 0 {
				return
			}
		case map[string]any:
			if len(x) == 0 {
				return
			}
		}
		m[k] = v
	}
	if ev.Timestamp != nil {
		m["timestamp"] = *ev.Timestamp
	}
	put("rawEvent", ev.RawEvent)
	put("metadata", ev.Metadata)
	put("threadId", ev.ThreadID)
	put("runId", ev.RunID)
	put("parentRunId", ev.ParentRunID)
	put("message", ev.Message)
	put("code", ev.Code)
	put("stepName", ev.StepName)
	put("messageId", ev.MessageID)
	put("role", ev.Role)
	put("delta", ev.Delta)
	put("toolCallId", ev.ToolCallID)
	put("toolName", ev.ToolName)
	put("args", ev.Args)
	put("content", ev.Content)
	put("result", ev.Result)
	put("snapshot", ev.Snapshot)
	if len(ev.DeltaOps) > 0 {
		m["delta"] = ev.DeltaOps
	}
	put("activityType", ev.ActivityType)
	put("name", ev.Name)
	put("value", ev.Value)
	put("event", ev.Event)
	for k, v := range ev.Fields {
		if _, exists := m[k]; !exists {
			m[k] = v
		}
	}
	return m
}

func mapToEvent(m map[string]any) Event {
	ev := Event{Fields: map[string]any{}}
	known := map[string]bool{}
	takeStr := func(k string, dst *string) {
		known[k] = true
		if s, ok := m[k].(string); ok {
			*dst = s
		}
	}
	takeAny := func(k string, dst *any) {
		known[k] = true
		if v, ok := m[k]; ok {
			*dst = v
		}
	}
	takeStr("type", &ev.Type)
	if ts, ok := asInt64(m["timestamp"]); ok {
		ev.Timestamp = &ts
		known["timestamp"] = true
	}
	takeAny("rawEvent", &ev.RawEvent)
	if md, ok := m["metadata"].(map[string]any); ok {
		ev.Metadata = md
		known["metadata"] = true
	}
	takeStr("threadId", &ev.ThreadID)
	takeStr("runId", &ev.RunID)
	takeStr("parentRunId", &ev.ParentRunID)
	takeStr("message", &ev.Message)
	takeStr("code", &ev.Code)
	takeStr("stepName", &ev.StepName)
	takeStr("messageId", &ev.MessageID)
	takeStr("role", &ev.Role)
	takeStr("toolCallId", &ev.ToolCallID)
	takeStr("toolName", &ev.ToolName)
	takeStr("args", &ev.Args)
	takeStr("activityType", &ev.ActivityType)
	takeStr("name", &ev.Name)
	takeAny("content", &ev.Content)
	takeAny("result", &ev.Result)
	takeAny("snapshot", &ev.Snapshot)
	takeAny("value", &ev.Value)
	takeAny("event", &ev.Event)
	known["delta"] = true
	switch d := m["delta"].(type) {
	case string:
		ev.Delta = d
	case []any:
		ev.DeltaOps = d
	}
	for k, v := range m {
		if !known[k] {
			ev.Fields[k] = v
		}
	}
	if len(ev.Fields) == 0 {
		ev.Fields = nil
	}
	return ev
}

func asInt64(v any) (int64, bool) {
	switch x := v.(type) {
	case float64:
		return int64(x), true
	case int64:
		return x, true
	case int:
		return int64(x), true
	case json.Number:
		n, err := x.Int64()
		return n, err == nil
	}
	return 0, false
}
