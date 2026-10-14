package vmm

import (
	"reflect"
	"testing"
)

func TestToolResultValueKeepsMedia(t *testing.T) {
	v, err := ToolResultValue(`{"content":[{"type":"text","text":"Here"},{"type":"image","data":"AAA","mimeType":"image/png"}]}`)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"text": "Here", "media": []any{map[string]any{"url": "data:image/png;base64,AAA", "mime": "image/png"}}}
	if !reflect.DeepEqual(v, want) {
		t.Fatalf("%#v", v)
	}
	v, _ = ToolResultValue(`{"content":[{"type":"image","data":"AAA","mimeType":"image/png"}],"structuredContent":{"title":"x"}}`)
	if m := v.(map[string]any); m["title"] != "x" || m["media"] == nil {
		t.Fatalf("%#v", v)
	}
	v, _ = ToolResultValue(`{"content":[{"type":"text","text":"{\"a\":1}"}]}`)
	if !reflect.DeepEqual(v, map[string]any{"a": float64(1)}) {
		t.Fatalf("%#v", v)
	}
}
