package crypto

import (
	"strings"
	"testing"
)

func TestSecretEncryption(t *testing.T) {
	master := strings.Repeat("01", 64)
	a, err := SealSecret("api-key", master, "provider/1")
	if err != nil {
		t.Fatal(err)
	}
	b, err := SealSecret("api-key", master, "provider/1")
	if err != nil {
		t.Fatal(err)
	}
	if a == b || strings.Contains(a, "api-key") {
		t.Fatal("encryption must randomize and conceal credentials")
	}
	if plain, err := OpenSecret(a, master, "provider/1"); err != nil || plain != "api-key" {
		t.Fatalf("round trip: %q %v", plain, err)
	}
	for _, tc := range []struct{ sealed, key, context string }{
		{a, strings.Repeat("02", 64), "provider/1"},
		{a, master, "provider/2"},
		{a[:len(a)-4] + "AAAA", master, "provider/1"},
		{SecretPrefix + "AA", master, "provider/1"},
		{"tradera:secret:v2:AA", master, "provider/1"},
	} {
		if _, err := OpenSecret(tc.sealed, tc.key, tc.context); err == nil {
			t.Fatal("invalid ciphertext/key/context was accepted")
		}
	}
	for _, key := range []string{"", "changeme", strings.Repeat("01", 32)} {
		if _, err := SealSecret("key", key, "provider/1"); err == nil {
			t.Fatal("missing or malformed master accepted")
		}
	}
}
