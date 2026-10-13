package signing

import (
	"testing"

	"github.com/tradera/tradera/pkg/crypto"
)

func TestSignVerifyReplay(t *testing.T) {
	kp, _ := crypto.Generate()
	headers, err := SignRequest(kp.PrivateHex(), "POST", "/v1/users/x", []byte(`{"a":1}`))
	if err != nil {
		t.Fatal(err)
	}
	guard := NewReplayGuard()
	if err := guard.VerifyRequest(kp.PublicHex(), "u1", "POST", "/v1/users/x", headers, []byte(`{"a":1}`)); err != nil {
		t.Fatal(err)
	}
	// Replay must be rejected.
	if err := guard.VerifyRequest(kp.PublicHex(), "u1", "POST", "/v1/users/x", headers, []byte(`{"a":1}`)); err == nil {
		t.Fatal("replay must be rejected")
	}
	// Tampered body must fail on a fresh guard.
	guard2 := NewReplayGuard()
	if err := guard2.VerifyRequest(kp.PublicHex(), "u1", "POST", "/v1/users/x", headers, []byte(`{"a":2}`)); err == nil {
		t.Fatal("tampered body must fail")
	}
}

func TestSignRequestMissingHeaders(t *testing.T) {
	kp, _ := crypto.Generate()
	guard := NewReplayGuard()
	err := guard.VerifyRequest(kp.PublicHex(), "u1", "POST", "/v1/users/x", map[string]string{}, []byte(`{}`))
	if err == nil {
		t.Fatal("missing headers must fail")
	}
}
