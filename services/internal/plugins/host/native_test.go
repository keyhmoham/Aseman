package host_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// Run after make plugins: TRADERA_NATIVE_TEST=1 go test ./internal/plugins/host.
func TestNativeNamespaceLifecycle(t *testing.T) {
	if os.Getenv("TRADERA_NATIVE_TEST") != "1" {
		t.Skip("set TRADERA_NATIVE_TEST=1 after make plugins")
	}
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command("go", "run", "-trimpath", "./internal/plugins/host/testdata/smoke")
	command.Dir = root
	command.Env = append(os.Environ(), "CGO_ENABLED=1")
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("native plugin lifecycle failed: %v\n%s", err, output)
	}
	t.Log(string(output))
}
