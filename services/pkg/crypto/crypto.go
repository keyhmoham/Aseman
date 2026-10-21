// Package crypto provides the identity and integrity primitives for aseman:
// Ed25519 keypairs for accounts and nodes, password-encrypted private keys,
// request signing/verification and a canonical payload format.
package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"

	"golang.org/x/crypto/scrypt"
)

// Keypair is an Ed25519 identity.
type Keypair struct {
	Public  ed25519.PublicKey
	Private ed25519.PrivateKey
}

// Generate creates a fresh Ed25519 keypair.
func Generate() (*Keypair, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	return &Keypair{Public: pub, Private: priv}, nil
}

// PublicHex renders the public key as hex.
func (k *Keypair) PublicHex() string { return hex.EncodeToString(k.Public) }

// PrivateHex renders the private key as hex.
func (k *Keypair) PrivateHex() string { return hex.EncodeToString(k.Private) }

// Sign signs a message and returns the 64-byte signature.
func Sign(privateHex string, msg []byte) ([]byte, error) {
	priv, err := decodePrivate(privateHex)
	if err != nil {
		return nil, err
	}
	return ed25519.Sign(priv, msg), nil
}

// SignHex signs a message and returns the signature as hex.
func SignHex(privateHex string, msg []byte) (string, error) {
	sig, err := Sign(privateHex, msg)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(sig), nil
}

// Verify checks an Ed25519 signature over a message with a public key.
func Verify(publicHex string, msg, sig []byte) bool {
	pub, err := hex.DecodeString(publicHex)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(pub), msg, sig)
}

// VerifyHex verifies a hex-encoded signature.
func VerifyHex(publicHex string, msg []byte, sigHex string) bool {
	sig, err := hex.DecodeString(sigHex)
	if err != nil {
		return false
	}
	return Verify(publicHex, msg, sig)
}

// ParsePublicKey decodes a hex public key for transport/display.
func ParsePublicKey(publicHex string) (ed25519.PublicKey, error) {
	b, err := hex.DecodeString(publicHex)
	if err != nil || len(b) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("invalid public key")
	}
	return ed25519.PublicKey(b), nil
}

// RequestPayload builds the canonical bytes signed for every request. The
// bodyHash is the hex sha256 of the request body. The nonce prevents replay and
// the timestamp bounds the freshness window.
func RequestPayload(method, path, nonce, timestamp, bodyHash string) []byte {
	return []byte(method + "\n" + path + "\n" + nonce + "\n" + timestamp + "\n" + bodyHash)
}

// BodyHash returns the hex sha256 of a body.
func BodyHash(body []byte) string {
	h := sha256.Sum256(body)
	return hex.EncodeToString(h[:])
}

// NewNonce returns a fresh 16-byte hex nonce.
func NewNonce() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// --- password-encrypted private keys ---

const (
	scryptN      = 1 << 15
	scryptR      = 8
	scryptP      = 1
	encKeyLength = 32
	saltLength   = 16
	nonceLength  = 12
)

// EncryptPrivateKey encrypts a private key hex string with a password-derived
// key (scrypt + AES-256-GCM). Output format: hex(salt || nonce || ciphertext).
func EncryptPrivateKey(privateHex, password string) (string, error) {
	salt := make([]byte, saltLength)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key, err := scrypt.Key([]byte(password), salt, scryptN, scryptR, scryptP, encKeyLength)
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, nonceLength)
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	ciphertext := gcm.Seal(nil, nonce, []byte(privateHex), nil)
	out := make([]byte, 0, saltLength+nonceLength+len(ciphertext))
	out = append(out, salt...)
	out = append(out, nonce...)
	out = append(out, ciphertext...)
	return hex.EncodeToString(out), nil
}

// DecryptPrivateKey recovers the private key hex from an encrypted blob.
func DecryptPrivateKey(encHex, password string) (string, error) {
	b, err := hex.DecodeString(encHex)
	if err != nil || len(b) < saltLength+nonceLength {
		return "", fmt.Errorf("invalid encrypted key blob")
	}
	salt := b[:saltLength]
	nonce := b[saltLength : saltLength+nonceLength]
	ciphertext := b[saltLength+nonceLength:]
	key, err := scrypt.Key([]byte(password), salt, scryptN, scryptR, scryptP, encKeyLength)
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	plain, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return "", fmt.Errorf("decrypt failed (wrong password?)")
	}
	return string(plain), nil
}

func decodePrivate(privateHex string) (ed25519.PrivateKey, error) {
	b, err := hex.DecodeString(privateHex)
	if err != nil || len(b) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("invalid private key")
	}
	return ed25519.PrivateKey(b), nil
}

// Must is a tiny helper that panics on error (for config-time constants).
func Must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}
