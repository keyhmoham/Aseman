package host_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// Run after make plugins: ASEMAN_NATIVE_TEST=1 go test ./internal/plugins/host.
func TestNativeNamespaceLifecycle(t *testing.T) {
	if os.Getenv("ASEMAN_NATIVE_TEST") != "1" {
		t.Skip("set ASEMAN_NATIVE_TEST=1 after make plugins")
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

// Run after make plugins, as root on a throwaway machine (the space's computer
// is this machine): ASEMAN_PLATFORM_E2E=1 go test ./internal/plugins/host -run PlatformE2E.
func TestPlatformE2E(t *testing.T) {
	if os.Getenv("ASEMAN_PLATFORM_E2E") != "1" {
		t.Skip("set ASEMAN_PLATFORM_E2E=1 after make plugins, on a throwaway machine")
	}
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command("go", "run", "-trimpath", "./internal/plugins/host/testdata/platform")
	command.Dir = root
	command.Env = append(os.Environ(), "CGO_ENABLED=1")
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("platform end to end failed: %v\n%s", err, output)
	}
	t.Log(string(output))
}

// TestWorkflowE2E runs the workflow installer on a whole node: the
// documented example from the console, a rerun, a key's workflow through
// the aseman CLI and a rollback (testdata/workflow). As root on a throwaway
// machine, after make plugins: ASEMAN_WORKFLOW_E2E=1 go test ./internal/plugins/host -run WorkflowE2E.
func TestWorkflowE2E(t *testing.T) {
	if os.Getenv("ASEMAN_WORKFLOW_E2E") != "1" {
		t.Skip("set ASEMAN_WORKFLOW_E2E=1 after make plugins, on a throwaway machine")
	}
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	command := exec.Command("go", "run", "-trimpath", "./internal/plugins/host/testdata/workflow")
	command.Dir = root
	command.Env = append(os.Environ(), "CGO_ENABLED=1")
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("workflow end to end failed: %v\n%s", err, output)
	}
	t.Log(string(output))
}
