package spaces

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"unicode/utf8"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
	"golang.org/x/net/html"
)

type sourceCheck struct {
	Name   string `json:"name"`
	Passed bool   `json:"passed"`
	Detail string `json:"detail,omitempty"`
}

type inlineScript struct {
	Source string `json:"source"`
	Module bool   `json:"module"`
}

type htmlInspection struct {
	Path        string           `json:"path,omitempty"`
	SHA256      string           `json:"sha256"`
	Title       string           `json:"title"`
	IDs         []string         `json:"ids"`
	Headings    []string         `json:"headings"`
	Elements    map[string]int   `json:"elements"`
	Forms       []map[string]any `json:"forms"`
	Assets      []string         `json:"script_references"`
	Checks      []sourceCheck    `json:"checks"`
	Truncated   bool             `json:"inventory_truncated,omitempty"`
	Limitations []string         `json:"limitations"`
}

// Static inspection uses the standard HTML parser and the sandbox's actual JS
// engine. It reports the observed structure instead of inventing required IDs.
func inspectHTML(data []byte) (htmlInspection, []inlineScript, error) {
	root, err := html.Parse(strings.NewReader(string(data)))
	if err != nil {
		return htmlInspection{}, nil, err
	}
	result := htmlInspection{
		SHA256: fmt.Sprintf("%x", sha256.Sum256(data)), Elements: map[string]int{},
		Limitations: []string{"Static source inspection only. Browser rendering, CSS layout, interactions, submission behavior and asset availability are not verified."},
	}
	ids, links, scripts := map[string]bool{}, []string{}, []inlineScript{}
	duplicates := []string{}
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if n.Type == html.ElementNode {
			if _, exists := result.Elements[n.Data]; exists || len(result.Elements) < 100 {
				result.Elements[n.Data]++
			} else {
				result.Truncated = true
			}
			id := htmlAttr(n, "id")
			if id != "" {
				if ids[id] {
					duplicates = append(duplicates, id)
				}
				ids[id] = true
				if len(result.IDs) < 100 {
					result.IDs = append(result.IDs, id)
				} else {
					result.Truncated = true
				}
			}
			if n.Data == "title" {
				result.Title = htmlText(n, 200)
			}
			if len(n.Data) == 2 && n.Data[0] == 'h' && n.Data[1] >= '1' && n.Data[1] <= '6' && len(result.Headings) < 50 {
				result.Headings = append(result.Headings, htmlText(n, 200))
			}
			if n.Data == "a" && strings.HasPrefix(htmlAttr(n, "href"), "#") && len(htmlAttr(n, "href")) > 1 {
				links = append(links, strings.TrimPrefix(htmlAttr(n, "href"), "#"))
			}
			if n.Data == "form" && len(result.Forms) < 20 {
				fields := []map[string]any{}
				var inputs func(*html.Node)
				inputs = func(field *html.Node) {
					if field.Type == html.ElementNode && (field.Data == "input" || field.Data == "textarea" || field.Data == "select") && len(fields) < 50 {
						fields = append(fields, map[string]any{"tag": field.Data, "id": htmlAttr(field, "id"), "name": htmlAttr(field, "name"), "type": htmlAttr(field, "type"), "required": htmlHasAttr(field, "required")})
					}
					for child := field.FirstChild; child != nil; child = child.NextSibling {
						inputs(child)
					}
				}
				inputs(n)
				result.Forms = append(result.Forms, map[string]any{"id": id, "fields": fields})
			}
			if n.Data == "script" {
				if src := htmlAttr(n, "src"); src != "" {
					if len(result.Assets) < 50 {
						result.Assets = append(result.Assets, truncateText(src, 200))
					} else {
						result.Truncated = true
					}
				} else {
					typeName := strings.ToLower(htmlAttr(n, "type"))
					if typeName == "" || typeName == "text/javascript" || typeName == "application/javascript" || typeName == "module" {
						var source strings.Builder
						for child := n.FirstChild; child != nil; child = child.NextSibling {
							if child.Type == html.TextNode {
								source.WriteString(child.Data)
							}
						}
						scripts = append(scripts, inlineScript{Source: source.String(), Module: typeName == "module"})
					}
				}
			}
		}
		for child := n.FirstChild; child != nil; child = child.NextSibling {
			walk(child)
		}
	}
	walk(root)
	missing := []string{}
	for _, target := range links {
		if decoded, err := url.PathUnescape(target); err == nil {
			target = decoded
		}
		if !ids[target] {
			missing = append(missing, target)
		}
	}
	result.Checks = []sourceCheck{
		{Name: "HTML parsed with standard HTML parser", Passed: true},
		{Name: "Element IDs are unique", Passed: len(duplicates) == 0, Detail: truncateText(strings.Join(duplicates, ", "), 1000)},
		{Name: "Fragment links resolve to actual element IDs", Passed: len(missing) == 0, Detail: truncateText(strings.Join(missing, ", "), 1000)},
	}
	return result, scripts, nil
}

func htmlAttr(n *html.Node, name string) string {
	for _, attr := range n.Attr {
		if attr.Key == name {
			return attr.Val
		}
	}
	return ""
}

func htmlHasAttr(n *html.Node, name string) bool {
	for _, attr := range n.Attr {
		if attr.Key == name {
			return true
		}
	}
	return false
}

func htmlText(n *html.Node, limit int) string {
	var text strings.Builder
	var walk func(*html.Node)
	walk = func(node *html.Node) {
		if node.Type == html.TextNode && text.Len() < limit {
			text.WriteString(node.Data)
		}
		for child := node.FirstChild; child != nil; child = child.NextSibling {
			walk(child)
		}
	}
	walk(n)
	return truncateText(strings.Join(strings.Fields(text.String()), " "), limit)
}

func (s *Service) inspectSandboxHTML(ctx context.Context, spaceID identity.ID, name string) (string, error) {
	if !vmm.ExecutionFrom(ctx).Allows("sandbox_exec") {
		return "", errs.Permission("sandbox filesystem access is not granted")
	}
	data, err := s.sandboxReadFile(ctx, spaceID, name)
	if err != nil {
		return "", err
	}
	if !utf8.Valid(data) {
		return "", errs.InvalidArgument("HTML inspection requires UTF-8 source")
	}
	inspection, scripts, err := inspectHTML(data)
	if err != nil {
		return "", errs.Wrap(errs.CodeInvalidArgument, err, "parse sandbox HTML")
	}
	inspection.Path = name
	scriptBytes := 0
	for _, script := range scripts {
		scriptBytes += len(script.Source)
	}
	scriptPayload, _ := json.Marshal(scripts)
	if scriptBytes > 40000 || len(scriptPayload) > 60000 || len(scripts) > 50 {
		inspection.Limitations = append(inspection.Limitations, "Inline scripts exceed the bounded checker transfer; use file-based sandbox syntax checks.")
	} else if len(scripts) > 0 {
		output, err := s.SandboxExec(ctx, spaceID, scriptCheckCommand(scripts))
		var checks []sourceCheck
		if err != nil || !strings.HasPrefix(output, "exit=0\n") || json.Unmarshal([]byte(strings.TrimSpace(strings.TrimPrefix(output, "exit=0\n"))), &checks) != nil {
			inspection.Limitations = append(inspection.Limitations, "JavaScript syntax checking could not run; Node may be unavailable.")
		} else {
			inspection.Checks = append(inspection.Checks, checks...)
		}
	}
	encoded, err := json.Marshal(inspection)
	if len(encoded) > 16000 {
		// Keep complete check verdicts and valid JSON when metadata is unusually
		// large. The original source remains available through focused reads.
		inspection.Truncated = true
		inspection.IDs, inspection.Headings, inspection.Forms, inspection.Assets = nil, nil, nil, nil
		for index := range inspection.Checks {
			inspection.Checks[index].Detail = truncateText(inspection.Checks[index].Detail, 64)
		}
		encoded, err = json.Marshal(inspection)
	}
	return "Static source inspection (observations and syntax checks, not browser verification):\n" + string(encoded), err
}

// No process substitution or shell-specific temporary-file templates. Scripts
// are parsed, never executed; module syntax uses Node's normal module parser.
func scriptCheckCommand(scripts []inlineScript) string {
	encoded, _ := json.Marshal(scripts)
	return "node - <<'ASEMAN_JS_CHECK'\n" + `const fs = require('fs'), vm = require('vm'), os = require('os'), path = require('path'), cp = require('child_process');
const scripts = JSON.parse(Buffer.from('` + base64.StdEncoding.EncodeToString(encoded) + `', 'base64').toString('utf8'));
const checks = scripts.map((script, index) => {
  const check = {name: 'Inline JavaScript syntax #' + (index + 1), passed: false};
  let dir;
  try {
    if (script.module) {
      dir = fs.mkdtempSync(path.join(os.tmpdir(), 'aseman-js-check-'));
      const file = path.join(dir, 'script.mjs'); fs.writeFileSync(file, script.source);
      const result = cp.spawnSync(process.execPath, ['--check', file], {encoding: 'utf8', timeout: 10000});
      if (result.status !== 0) throw new Error((result.stderr || 'Module syntax check failed').slice(-1000));
    } else new vm.Script(script.source, {filename: 'inline-' + (index + 1) + '.js'});
    check.passed = true;
  } catch (error) { check.detail = String(error.message).slice(0, 1000); }
  finally { if (dir) fs.rmSync(dir, {recursive: true, force: true}); }
  return check;
});
console.log(JSON.stringify(checks));
ASEMAN_JS_CHECK`
}
