package users

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testKey(t *testing.T) (*ecdsa.PrivateKey, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return key, string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
}

// The key reaches the node through an env file, where a multi-line PEM is
// awkward: every way it is likely to be written has to load.
func TestAPNsKeyLoadsHoweverItIsGiven(t *testing.T) {
	want, text := testKey(t)
	path := filepath.Join(t.TempDir(), "AuthKey.p8")
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	for name, given := range map[string]string{
		"the text":           text,
		"escaped newlines":   strings.ReplaceAll(strings.TrimSpace(text), "\n", `\n`),
		"a path to the file": path,
		"base64 of the file": base64.StdEncoding.EncodeToString([]byte(text)),
	} {
		got, err := parseAPNsKey(given)
		if err != nil || !got.Equal(want) {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := parseAPNsKey(""); err == nil {
		t.Error("no key is not a key")
	}
	if _, err := parseAPNsKey("not a key"); err == nil {
		t.Error("garbage is not a key")
	}
}

// Apple checks the token's signature: it must verify against the key, in the
// r-and-s-side-by-side form a JWT uses.
func TestProviderTokenIsAValidES256JWT(t *testing.T) {
	key, _ := testKey(t)
	signed, err := signES256(key, map[string]any{"alg": "ES256", "kid": "KEY123"}, map[string]any{"iss": "TEAM123", "iat": 1})
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(signed, ".")
	if len(parts) != 3 {
		t.Fatalf("not a JWT: %s", signed)
	}
	var header map[string]any
	raw, _ := base64.RawURLEncoding.DecodeString(parts[0])
	if json.Unmarshal(raw, &header) != nil || header["alg"] != "ES256" || header["kid"] != "KEY123" {
		t.Fatalf("header %s", raw)
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		t.Fatalf("signature is %d bytes", len(sig))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(&key.PublicKey, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		t.Fatal("the signature does not verify")
	}
}

func TestNotificationPayload(t *testing.T) {
	body, err := apnsPayload(PushNote{Title: "Launch plan", Body: "Researcher: here is the report", Kind: "message", Space: "s1", Room: "r1"})
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Aps struct {
			Alert  struct{ Title, Body string }
			Sound  string
			Thread string `json:"thread-id"`
		}
		Body struct{ Kind, Space, Room string }
	}
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatal(err)
	}
	if got.Aps.Alert.Title != "Launch plan" || got.Aps.Alert.Body != "Researcher: here is the report" || got.Aps.Sound != "default" || got.Aps.Thread != "s1" {
		t.Fatalf("aps: %+v", got.Aps)
	}
	// What the app reads to open the right project when the notification is
	// tapped: under "body", where its notification library looks.
	if got.Body.Kind != "message" || got.Body.Space != "s1" || got.Body.Room != "r1" {
		t.Fatalf("routing: %+v", got.Body)
	}
}

func TestPushHosts(t *testing.T) {
	if apnsHost("development") != "https://api.sandbox.push.apple.com" || apnsHost("production") != "https://api.push.apple.com" || apnsHost("") != "https://api.push.apple.com" {
		t.Fatal("a token goes to the service that issued it; anything unknown is production")
	}
}
