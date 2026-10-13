package vmm

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestEnvironmentContracts(t *testing.T) {
	seen := map[string]bool{}
	for _, tool := range Builtins() {
		if seen[tool.Name] {
			t.Fatalf("duplicate tool %s", tool.Name)
		}
		seen[tool.Name] = true
		var args map[string]any
		if err := json.Unmarshal([]byte(tool.Example), &args); err != nil {
			t.Fatalf("%s example: %v", tool.Name, err)
		}
		required, _ := tool.Parameters["required"].([]string)
		for _, key := range required {
			if _, ok := args[key]; !ok {
				t.Fatalf("%s example missing %s", tool.Name, key)
			}
		}
	}
}

func TestBuiltinsAreIndependentCopies(t *testing.T) {
	tools := Builtins()
	tools[0].Parameters["properties"].(map[string]any)["command"] = "changed"
	if Builtins()[0].Parameters["properties"].(map[string]any)["command"] == "changed" {
		t.Fatal("builtin schemas are shared")
	}
	for _, name := range Names() {
		if strings.HasPrefix(name, "memory_") {
			t.Fatalf("%s: memory is files in the shared sandbox, not a platform tool", name)
		}
	}
}
