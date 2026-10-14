package a2ui

import (
	"encoding/json"
	"strings"
	"testing"
)

func decode(t *testing.T, s string) any {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func byID(list []map[string]any) map[string]map[string]any {
	out := map[string]map[string]any{}
	for _, c := range list {
		out[c["id"].(string)] = c
	}
	return out
}

func TestFlattenRepairsModelShapes(t *testing.T) {
	for name, src := range map[string]string{
		"inline children": `[{"id":"root","component":"Column","children":[
			{"component":"Text","text":"Hi"},
			{"type":"Card","child":{"component":"Image","url":"{/url}"}}]}]`,
		"type alias, no ids": `[{"type":"Column","children":[{"kind":"text","text":"Hi"}]}]`,
		"shorthand":          `[{"Column":{"id":"root","children":[{"Text":{"text":"Hi"}}]}}]`,
		"keyed by id":        `{"root":{"component":"Column","children":["t"]},"t":{"component":"Text","text":"Hi"}}`,
		"single component":   `{"component":"Card","child":{"component":"Text","text":"Hi"}}`,
		"no root, many":      `[{"component":"Text","text":"a"},{"component":"Text","text":"b"}]`,
		"tabs and modal": `[{"id":"root","component":"Tabs","tabs":[{"title":"A","child":{"component":"Text","text":"a"}}]},
			{"id":"m","component":"Modal","trigger":{"component":"Text","text":"open"},"content":{"component":"Text","text":"body"}}]`,
	} {
		t.Run(name, func(t *testing.T) {
			list := Flatten(decode(t, src))
			if err := Check(list); err != nil {
				t.Fatalf("%v: %v", err, list)
			}
			ids := byID(list)
			if len(ids) != len(list) {
				t.Fatalf("duplicate ids: %v", list)
			}
			for _, c := range list {
				for _, key := range []string{"child", "trigger", "content"} {
					if v, ok := c[key]; ok {
						s, isID := v.(string)
						if !isID || ids[s] == nil {
							t.Fatalf("%s of %v is not a defined id", key, c)
						}
					}
				}
				if ch, ok := c["children"].([]any); ok {
					for _, v := range ch {
						if s, _ := v.(string); ids[s] == nil {
							t.Fatalf("child %v of %v is not a defined id", v, c)
						}
					}
				}
			}
		})
	}
}

func TestFlattenKeepsGoodListsAndDropsUntyped(t *testing.T) {
	list := Flatten(decode(t, `[{"id":"root","component":"Column","children":["a","x"]},
		{"id":"a","component":"Chart","type":"line"},{"id":"x","note":"no type"}]`))
	ids := byID(list)
	if len(list) != 2 || ids["a"]["type"] != "line" || ids["a"]["component"] != "Chart" {
		t.Fatalf("%v", list)
	}
	if ch := ids["root"]["children"].([]any); len(ch) != 1 || ch[0] != "a" {
		t.Fatalf("children %v", ch)
	}
	// A list template keeps its componentId reference.
	list = Flatten(decode(t, `[{"id":"root","component":"List","children":{"componentId":{"component":"Text","text":"{name}"},"path":"/items"}}]`))
	if err := Check(list); err != nil {
		t.Fatal(err)
	}
	ch := byID(list)["root"]["children"].(map[string]any)
	if id, _ := ch["componentId"].(string); byID(list)[id] == nil || ch["path"] != "/items" {
		t.Fatalf("%v", list)
	}
}

func TestCheckNamesTheBrokenComponent(t *testing.T) {
	err := Check([]map[string]any{{"id": "root", "component": "Column"}, {"text": "x"}})
	if err == nil || !strings.Contains(err.Error(), "component #2") || !strings.Contains(err.Error(), "text") {
		t.Fatalf("%v", err)
	}
}
