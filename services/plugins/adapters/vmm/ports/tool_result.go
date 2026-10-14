package vmm

import (
	"encoding/json"
	"strings"

	"github.com/tradera/tradera/pkg/errs"
)

const CodeToolExecutionFailed errs.Code = "TOOL_EXECUTION_FAILED"
const CodeSandboxMemoryLimit errs.Code = "SANDBOX_MEMORY_LIMIT"

// ToolFailureResult preserves partial output and gives the model actionable,
// typed feedback. It never claims a failed mutation had no side effects or
// automatically retries one. The prefix keeps historical error detection intact.
func ToolFailureResult(tool, output string, err error) string {
	if err == nil {
		return output
	}
	recovery := "Inspect the error and recorded outcome before choosing a corrected action. Do not repeat an unchanged failed call or assume a mutation had no effect."
	switch errs.CodeOf(err) {
	case errs.CodeInvalidArgument:
		recovery = "Correct the arguments using the attached tool schema. Do not repeat the same invalid arguments."
		if tool == "file_edit" {
			recovery += " Use the error's observed source context or a focused file_read to construct an exact unique match from current bytes."
		}
	case errs.CodePermission, errs.CodeUnauthenticated:
		recovery = "This operation is not authorized. Use granted capabilities or report the access requirement; do not bypass it."
	case errs.CodeNotFound:
		recovery = "Check the exact resource identifier or sandbox path using a focused lookup; do not invent one."
	case errs.CodeConflict:
		if tool == "file_edit" {
			recovery = "Read or search the relevant source range, then construct an exact unique replacement from the current bytes. Preserve existing work."
		}
	case CodeToolExecutionFailed:
		recovery = "Inspect the exit code and diagnostic output. Fix the command or actual code defect before a focused retry. If a utility is missing, choose an available equivalent or report the limitation; do not keep probing it. Commands can have partial effects despite a nonzero exit."
	case CodeSandboxMemoryLimit:
		recovery = "The sandbox exhausted its configured memory. Preserve existing files, reduce build concurrency or stop only unnecessary processes, then retry after a concrete resource correction. If the configured limits are insufficient, ask for the required resource change. Do not repeat an unchanged build or confuse an incomplete build with a verified artifact."
	}
	payload, _ := json.Marshal(map[string]any{"ok": false, "tool": tool, "error": map[string]any{"code": errs.CodeOf(err), "message": err.Error()}, "output": output, "recovery": recovery})
	return "error: " + string(payload)
}

// ToolResultValue is what an MCP tool result means as data: its structured
// content, else its text (as JSON when it is JSON). An error result is an
// error.
func ToolResultValue(reply string) (any, error) {
	var result map[string]any
	if json.Unmarshal([]byte(reply), &result) != nil || result == nil {
		var v any
		if json.Unmarshal([]byte(reply), &v) == nil {
			return v, nil
		}
		return reply, nil
	}
	if _, isMCP := result["content"]; !isMCP {
		if _, isMCP = result["structuredContent"]; !isMCP {
			return result, nil
		}
	}
	var texts []string
	if blocks, ok := result["content"].([]any); ok {
		for _, b := range blocks {
			if block, ok := b.(map[string]any); ok && block["type"] == "text" {
				if t, ok := block["text"].(string); ok {
					texts = append(texts, t)
				}
			}
		}
	}
	text := strings.Join(texts, "\n")
	if isErr, _ := result["isError"].(bool); isErr {
		return nil, errs.New(CodeToolExecutionFailed, "the tool reported an error: "+text)
	}
	var v any = text
	if sc, ok := result["structuredContent"]; ok && sc != nil {
		v = sc
	} else if json.Unmarshal([]byte(text), &v) != nil {
		v = text
	}
	return withMedia(v, result["content"]), nil
}

// withMedia adds the images, audio and linked files of a result's content
// blocks to its value (as "media": [{url, mime, name?}], urls being data:
// URIs or links), so frontends can show them; a value that is no object
// becomes {"text": value, "media": [...]}.
func withMedia(v any, content any) any {
	blocks, _ := content.([]any)
	var media []any
	for _, b := range blocks {
		block, _ := b.(map[string]any)
		switch block["type"] {
		case "image", "audio":
			data, _ := block["data"].(string)
			mime, _ := block["mimeType"].(string)
			if data != "" && mime != "" {
				media = append(media, map[string]any{"url": "data:" + mime + ";base64," + data, "mime": mime})
			}
		case "resource_link":
			if uri, _ := block["uri"].(string); uri != "" {
				media = append(media, map[string]any{"url": uri, "mime": block["mimeType"], "name": block["name"]})
			}
		case "resource":
			r, _ := block["resource"].(map[string]any)
			blob, _ := r["blob"].(string)
			mime, _ := r["mimeType"].(string)
			if blob != "" && mime != "" {
				media = append(media, map[string]any{"url": "data:" + mime + ";base64," + blob, "mime": mime, "name": r["uri"]})
			}
		}
	}
	if len(media) == 0 {
		return v
	}
	if m, ok := v.(map[string]any); ok {
		if _, taken := m["media"]; !taken {
			out := make(map[string]any, len(m)+1)
			for k, x := range m {
				out[k] = x
			}
			out["media"] = media
			return out
		}
		return m
	}
	if s, ok := v.(string); ok && s == "" {
		return map[string]any{"media": media}
	}
	return map[string]any{"text": v, "media": media}
}
