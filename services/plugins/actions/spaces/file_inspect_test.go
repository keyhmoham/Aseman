package spaces

import (
	"encoding/json"
	"os/exec"
	"strings"
	"testing"
)

func TestHTMLInspectionUsesActualMarkupAndDetectsBrokenReferences(t *testing.T) {
	source := []byte(`<!doctype html><title>Example &amp; Company</title><nav><a href="#platform">Platform</a></nav><main id="top"><section class="hero"><h1>Real hero</h1></section><section id="platform"><h2>Products</h2></section><form id="contact-form"><input name="email" type="email" required></form></main><script type="application/ld+json">{"name":"Example"}</script><script>const ready = true;</script>`)
	inspection, scripts, err := inspectHTML(source)
	if err != nil || inspection.Title != "Example & Company" || len(scripts) != 1 || inspection.Elements["section"] != 2 || len(inspection.Forms) != 1 {
		t.Fatalf("incorrect DOM inventory: %+v %v", inspection, err)
	}
	for _, check := range inspection.Checks {
		if !check.Passed {
			t.Fatal("valid markup with a class-based hero failed an invented selector", check)
		}
	}
	broken, _, err := inspectHTML([]byte(`<a href="#missing">Missing</a><p id="same"></p><p id="same"></p>`))
	if err != nil || broken.Checks[1].Passed || broken.Checks[2].Passed {
		t.Fatal("duplicate IDs or missing fragment targets were accepted")
	}
}

func TestInlineScriptsUseRealEngineWithoutExecutingThem(t *testing.T) {
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("Node is unavailable")
	}
	scripts := []inlineScript{
		{Source: "throw new Error('must not execute');"},
		{Source: "const = invalid;"},
		{Source: "export const value = 1;", Module: true},
	}
	command := scriptCheckCommand(scripts)
	output, err := exec.Command("sh", "-c", command).CombinedOutput()
	var checks []sourceCheck
	if err != nil || json.Unmarshal(output, &checks) != nil || len(checks) != 3 {
		t.Fatalf("engine check failed: %v %s", err, output)
	}
	if !checks[0].Passed || checks[1].Passed || !checks[2].Passed || !strings.Contains(checks[1].Detail, "Unexpected") {
		t.Fatal("syntax check executed code or misclassified module syntax", checks)
	}
}
