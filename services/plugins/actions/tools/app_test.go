package tools

import "testing"

func TestCommandDefsKeepAppMetadata(t *testing.T) {
	defs := commandDefs(map[string]any{"tools": []any{
		map[string]any{"name": "create_view", "inputSchema": map[string]any{"type": "object"},
			"_meta": map[string]any{"ui": map[string]any{"resourceUri": "ui://excalidraw/mcp-app.html"}}},
		map[string]any{"name": "save_checkpoint", "_meta": map[string]any{"ui": map[string]any{"visibility": []any{"app"}}}},
		map[string]any{"name": "legacy", "_meta": map[string]any{"ui/resourceUri": "ui://x/app.html"}},
		map[string]any{"name": "plain"},
	}})
	if defs[0]["ui"] != "ui://excalidraw/mcp-app.html" || defs[2]["ui"] != "ui://x/app.html" {
		t.Fatalf("%v", defs)
	}
	if _, ok := defs[3]["ui"]; ok {
		t.Fatalf("%v", defs[3])
	}
	if !appOnly(defs[1]) || appOnly(defs[0]) || appOnly(defs[3]) {
		t.Fatal("visibility")
	}
	if appOnly(map[string]any{"visibility": []any{"model", "app"}}) {
		t.Fatal("model and app is for agents too")
	}
}
