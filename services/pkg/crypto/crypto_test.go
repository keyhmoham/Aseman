package crypto

import (
	"strings"
	"testing"
)

func TestKeypairSignVerify(t *testing.T) {
	kp, err := Generate()
	if err != nil {
		t.Fatal(err)
	}
	if len(kp.Public) != 32 || len(kp.Private) != 64 {
		t.Fatal("bad key sizes")
	}
	msg := []byte("hello tradera")
	sig, err := SignHex(kp.PrivateHex(), msg)
	if err != nil {
		t.Fatal(err)
	}
	if !VerifyHex(kp.PublicHex(), msg, sig) {
		t.Fatal("signature should verify")
	}
	if VerifyHex(kp.PublicHex(), []byte("tampered"), sig) {
		t.Fatal("signature must not verify tampered message")
	}
	if VerifyHex("deadbeef", msg, sig) {
		t.Fatal("signature must not verify with wrong key")
	}
}

func TestEncryptDecryptPrivateKey(t *testing.T) {
	kp, _ := Generate()
	enc, err := EncryptPrivateKey(kp.PrivateHex(), "s3cret-pass")
	if err != nil {
		t.Fatal(err)
	}
	if strings.HasPrefix(enc, kp.PrivateHex()) {
		t.Fatal("ciphertext must not leak the plaintext")
	}
	got, err := DecryptPrivateKey(enc, "s3cret-pass")
	if err != nil {
		t.Fatal(err)
	}
	if got != kp.PrivateHex() {
		t.Fatal("round trip mismatch")
	}
	if _, err := DecryptPrivateKey(enc, "wrong-pass"); err == nil {
		t.Fatal("wrong password must fail")
	}
}

func TestRequestPayloadDeterministic(t *testing.T) {
	a := RequestPayload("POST", "/v1/auth/whoami", "n1", "1700000000", "hash")
	b := RequestPayload("POST", "/v1/auth/whoami", "n1", "1700000000", "hash")
	if string(a) != string(b) {
		t.Fatal("payload must be deterministic")
	}
	c := RequestPayload("POST", "/v1/auth/whoami", "n2", "1700000000", "hash")
	if string(a) == string(c) {
		t.Fatal("nonce must change the payload")
	}
}
