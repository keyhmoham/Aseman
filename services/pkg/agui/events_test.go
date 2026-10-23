package agui

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestConstructorsAndSSERoundTrip(t *testing.T) {
	events := []Event{
		NewRunStarted("thr-1", "run-1"),
		NewCustom(SurfaceCreate, map[string]any{"surfaceId": "s1", "catalog": CatalogID}),
		NewStateSnapshot(map[string]any{"k": 1}),
		NewStateDelta([]any{map[string]any{"op": "replace", "path": "/k", "value": 2}}),
		NewRunFinished("thr-1", "run-1"),
		NewRunError("boom"),
	}
	sse := EncodeSSE(events)
	if !strings.Contains(sse, `"type":"RUN_STARTED"`) || !strings.Contains(sse, "data: ") {
		t.Fatalf("sse: %s", sse)
	}
	for _, line := range strings.Split(sse, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		ev, err := DecodeEvent([]byte(strings.TrimPrefix(line, "data: ")))
		if err != nil {
			t.Fatal(err)
		}
		if ev.Type == "" {
			t.Fatal("empty type")
		}
	}
	maps := EventsToMaps(events)
	if len(maps) != len(events) || maps[0]["type"] != EventRunStarted {
		t.Fatalf("%v", maps)
	}
}

func TestSurfaceEventsAndApplyCustom(t *testing.T) {
	comps := []map[string]any{{"id": "root", "type": "Text", "text": "Hi"}}
	data := map[string]any{"n": 1}
	theme := map[string]any{"layout": "chat", "primaryColor": "#08f"}
	evs := SurfaceEvents("surf-1", comps, data, theme)
	if len(evs) < 3 {
		t.Fatalf("want create+update+patch(+snapshot), got %d", len(evs))
	}
	var st SurfaceState
	reg := map[string]*SurfaceState{}
	for _, ev := range evs {
		if ev.Type != EventCustom {
			continue
		}
		if err := ApplyCustomRegistry(reg, ev); err != nil {
			t.Fatal(err)
		}
		if err := st.ApplyCustom(ev); err != nil {
			t.Fatal(err)
		}
	}
	if st.SurfaceID != "surf-1" || st.Layout != "chat" || len(st.Components) != 1 {
		t.Fatalf("%+v", st)
	}
	if st.Data["n"] != 1 && st.Data["n"] != float64(1) {
		// ApplyCustom keeps native types from maps
		if st.Data["n"] != 1 {
			t.Fatalf("data: %v", st.Data)
		}
	}
	if reg["surf-1"] == nil || reg["surf-1"].Catalog != CatalogID {
		t.Fatalf("%v", reg)
	}
	del := NewCustom(SurfaceDelete, map[string]any{"surfaceId": "surf-1"})
	if err := ApplyCustomRegistry(reg, del); err != nil || reg["surf-1"] != nil {
		t.Fatalf("delete: %v %v", err, reg)
	}
}

func TestDecodeStateDelta(t *testing.T) {
	raw, _ := json.Marshal(map[string]any{
		"type":  EventStateDelta,
		"delta": []any{map[string]any{"op": "add", "path": "/x", "value": true}},
	})
	ev, err := DecodeEvent(raw)
	if err != nil || len(ev.DeltaOps) != 1 {
		t.Fatalf("%v %v", ev, err)
	}
}
