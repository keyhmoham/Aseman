package workflow

// SchemaID is where the published schema lives in the repository; editors
// read it from a document's "$schema" (a relative path works too).
const SchemaID = "https://raw.githubusercontent.com/keyhmoham/Aseman/main/docs/workflows/workflow.schema.json"

// JSONSchema is the workflow format as a JSON Schema (draft 2020-12), for
// editors and for checking documents before they are sent. The validator
// is still the authority: it also checks references, expressions and what
// the door allows. docs/workflows/workflow.schema.json is this, written out
// (TestSchemaFileIsCurrent keeps them the same).
func JSONSchema() map[string]any {
	str := map[string]any{"type": "string"}
	expr := map[string]any{"type": "string", "description": "a ${{ expression }} or text holding some"}
	anyVal := map[string]any{}
	duration := map[string]any{"description": "30s, 5m, 1h30m, or seconds", "oneOf": []any{
		map[string]any{"type": "string", "pattern": `^\s*(\d+(\.\d+)?|(\d+(\.\d+)?(ns|us|µs|ms|s|m|h))+)\s*$`},
		map[string]any{"type": "number", "minimum": 0},
	}}
	condition := map[string]any{"description": "a boolean, a bare expression, or ${{ … }}", "type": []any{"boolean", "string"}}
	object := func(props map[string]any, required ...string) map[string]any {
		o := map[string]any{"type": "object", "properties": props, "additionalProperties": false}
		if len(required) > 0 {
			o["required"] = required
		}
		return o
	}
	objOrExpr := map[string]any{"type": []any{"object", "string"}, "description": "an object, or one ${{ expression }} that is one"}
	ref := func(name string) map[string]any { return map[string]any{"$ref": "#/$defs/" + name} }
	steps := map[string]any{"type": "array", "items": ref("step")}
	id := map[string]any{"type": "string", "pattern": "^[A-Za-z_][A-Za-z0-9_]*$"}
	names := func(m map[string]any) map[string]any {
		return map[string]any{"type": "object", "propertyNames": map[string]any{"pattern": "^[A-Za-z_][A-Za-z0-9_]*$"}, "additionalProperties": m}
	}

	input := object(map[string]any{
		"type":        map[string]any{"enum": []any{"string", "number", "integer", "boolean", "object", "list", "array", "any"}},
		"description": str, "default": anyVal, "required": map[string]any{"type": "boolean"},
		"enum": map[string]any{"type": "array"}, "pattern": str,
		"min": map[string]any{"type": "number"}, "max": map[string]any{"type": "number"},
		"sensitive": map[string]any{"type": "boolean"},
	})
	retry := object(map[string]any{
		"attempts":  map[string]any{"type": "integer", "minimum": 1, "maximum": MaxAttempts},
		"delay":     duration,
		"backoff":   map[string]any{"type": "number", "minimum": 1, "maximum": 10},
		"max_delay": duration,
		"on":        map[string]any{"type": "array", "items": str},
	}, "attempts")
	call := object(map[string]any{
		"action": str, "with": anyVal, "items": str, "item": str, "id": str,
		"page": object(map[string]any{
			"limit": map[string]any{"type": "integer", "minimum": 1}, "max_pages": map[string]any{"type": "integer", "minimum": 1},
			"limit_field": str, "offset_field": str,
		}),
	}, "action")
	presets := PresetNames()
	anyNames := make([]any, len(presets))
	for i, p := range presets {
		anyNames[i] = p
	}
	upsert := object(map[string]any{
		"resource": map[string]any{"enum": anyNames},
		"define": object(map[string]any{
			"find": call, "create": call, "update": call, "delete": call,
			"match": map[string]any{"type": "object"}, "record_id": str, "compare": map[string]any{"type": "array", "items": str},
		}),
		"match": map[string]any{"type": "object"}, "with": objOrExpr, "create_with": objOrExpr, "update_with": objOrExpr,
		"mode":           map[string]any{"enum": []any{"upsert", "ensure", "update", "create"}},
		"skip_unchanged": map[string]any{"type": "boolean"}, "rollback": map[string]any{"type": "boolean"},
	})
	upsert["anyOf"] = []any{map[string]any{"required": []any{"resource"}}, map[string]any{"required": []any{"define"}}}
	command := map[string]any{"oneOf": []any{str, object(map[string]any{
		"run": str, "workdir": str, "expect": str, "env": map[string]any{"type": "object"}, "ignore_exit": map[string]any{"type": "boolean"},
	}, "run")}}
	sandbox := object(map[string]any{
		"space": str, "start": map[string]any{"type": "boolean"}, "root": str, "clean": map[string]any{"type": "boolean"},
		"files":  map[string]any{"type": "object", "additionalProperties": map[string]any{"oneOf": []any{str, ref("file")}}},
		"assets": str, "render": map[string]any{"type": "boolean"},
		"exec":    map[string]any{"oneOf": []any{command, map[string]any{"type": "array", "items": command}}},
		"workdir": str, "env": map[string]any{"type": "object"}, "proxy": map[string]any{"type": "object"}, "expect": str,
	}, "space")
	file := object(map[string]any{
		"content": str, "base64": str, "json": anyVal, "asset": str, "$raw": anyVal,
		"mode": map[string]any{"type": "string", "pattern": "^[0-7]{3,4}$"}, "template": map[string]any{"type": "boolean"},
	})
	asset := map[string]any{"oneOf": []any{str, func() map[string]any {
		a := object(map[string]any{
			"content": str, "base64": str, "json": anyVal, "mime": str, "template": map[string]any{"type": "boolean"},
			"mode": map[string]any{"type": "string", "pattern": "^[0-7]{3,4}$"},
		})
		a["oneOf"] = []any{map[string]any{"required": []any{"content"}}, map[string]any{"required": []any{"base64"}}, map[string]any{"required": []any{"json"}}}
		return a
	}()}}

	kinds := []string{"action", "upsert", "model", "sandbox", "wait", "set", "assert", "log", "sleep", "fail", "steps", "use"}
	oneKind := make([]any, len(kinds))
	for i, k := range kinds {
		oneKind[i] = map[string]any{"required": []any{k}}
	}
	step := object(map[string]any{
		"id": id, "name": str, "description": str, "if": condition,
		"action": map[string]any{"type": "string", "pattern": `^[a-z0-9_-]+\.[a-z0-9_]+$`}, "with": anyVal,
		"upsert": upsert,
		"model": object(map[string]any{
			"type": map[string]any{"enum": []any{"chat", "embeddings", "image", "speech", "transcription", "rerank", "decision"}},
			"body": objOrExpr,
		}, "body"),
		"sandbox": sandbox,
		"wait":    object(map[string]any{"action": str, "with": anyVal, "until": condition, "interval": duration, "timeout": duration}, "action", "until"),
		"set":     names(anyVal),
		"assert":  map[string]any{"oneOf": []any{condition, ref("check"), map[string]any{"type": "array", "items": map[string]any{"oneOf": []any{condition, ref("check")}}}}},
		"log":     anyVal, "sleep": duration, "fail": anyVal,
		"steps": steps, "parallel": map[string]any{"type": "boolean"}, "use": id,
		"for_each": anyVal, "as": id, "index_as": id,
		"concurrency": map[string]any{"type": "integer", "minimum": 1, "maximum": MaxConcurrency}, "collect": anyVal,
		"retry": retry, "timeout": duration, "continue_on_error": map[string]any{"type": "boolean"},
		"on_error": steps, "compensate": ref("step"), "outputs": anyVal, "export": names(anyVal),
		"sensitive": map[string]any{"type": "boolean"}, "plan": map[string]any{"enum": []any{"run", "skip"}},
	})
	step["oneOf"] = oneKind

	secret := object(map[string]any{"name": id, "description": str, "required": map[string]any{"type": "boolean"}})
	return map[string]any{
		"$schema":              "https://json-schema.org/draft/2020-12/schema",
		"$id":                  SchemaID,
		"title":                "Aseman workflow installer",
		"description":          "One document that brings up a product on Aseman through the developer API. See docs/WORKFLOWS.md.",
		"type":                 "object",
		"required":             []any{"aseman_workflow", "name", "steps"},
		"additionalProperties": false,
		"properties": map[string]any{
			"$schema":         str,
			"aseman_workflow": map[string]any{"const": FormatVersion},
			"name":            map[string]any{"type": "string", "minLength": 1},
			"description":     str, "version": str,
			"inputs": names(input),
			"secrets": map[string]any{"oneOf": []any{
				map[string]any{"type": "array", "items": map[string]any{"oneOf": []any{id, secret}}},
				names(object(map[string]any{"description": str, "required": map[string]any{"type": "boolean"}})),
			}},
			"vars": names(anyVal),
			"defaults": object(map[string]any{
				"retry": retry, "timeout": duration, "continue_on_error": map[string]any{"type": "boolean"},
				"with": map[string]any{"type": "object", "additionalProperties": map[string]any{"type": "object"}},
			}),
			"options": object(map[string]any{
				"rollback_on_failure": map[string]any{"type": "boolean"}, "timeout": duration,
				"max_steps": map[string]any{"type": "integer", "minimum": 1, "maximum": MaxSteps},
				"org":       str, "stamp_platform": map[string]any{"type": "boolean"}, "platform": str,
			}),
			"assets": map[string]any{"type": "object", "additionalProperties": asset},
			"templates": names(object(map[string]any{
				"description": str, "params": names(input), "steps": steps, "outputs": anyVal,
			}, "steps")),
			"steps":      map[string]any{"type": "array", "items": ref("step"), "minItems": 1},
			"on_failure": steps, "finally": steps,
			"outputs": map[string]any{"type": "object"},
		},
		"$defs": map[string]any{
			"step":  step,
			"file":  file,
			"check": object(map[string]any{"that": condition, "message": expr}, "that"),
		},
	}
}
