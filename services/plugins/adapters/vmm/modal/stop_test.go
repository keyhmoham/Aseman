package modal

import (
	"errors"
	"testing"

	modal "github.com/modal-labs/modal-client/go"
)

func TestFailedTerminationKeepsSandboxLiveForRetry(t *testing.T) {
	sb := &modal.Sandbox{}
	a := &Adapter{sandboxes: map[string]*sandboxState{"sb": {sb: sb}}}
	if err := a.finishSandboxStop("sb", sb, func() error { return errors.New("provider unavailable") }); err == nil {
		t.Fatal("termination failure was reported as success")
	}
	if a.liveSandbox("sb") != sb || a.sandboxes["sb"].slept {
		t.Fatal("failed termination hid the running sandbox")
	}
	if err := a.finishSandboxStop("sb", sb, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	if a.liveSandbox("sb") != nil || !a.sandboxes["sb"].slept {
		t.Fatal("successful termination did not mark the sandbox stopped")
	}
}

func TestStopDoesNotDetachAReplacementSandbox(t *testing.T) {
	old, replacement := &modal.Sandbox{}, &modal.Sandbox{}
	a := &Adapter{sandboxes: map[string]*sandboxState{"sb": {sb: old}}}
	if err := a.finishSandboxStop("sb", old, func() error {
		a.sandboxes["sb"] = &sandboxState{sb: replacement}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if a.liveSandbox("sb") != replacement {
		t.Fatal("stop of the old sandbox hid its replacement")
	}
}
