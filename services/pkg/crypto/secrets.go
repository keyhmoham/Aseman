package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strings"
)

const SecretPrefix = "aseman:secret:v1:"

// secretCipher derives a domain-separated encryption key from a high-entropy
// node identity key. A missing or malformed key must never allow plaintext writes.
func secretCipher(master string) (cipher.AEAD, error) {
	raw, err := hex.DecodeString(master)
	if err != nil || len(raw) != 64 {
		return nil, fmt.Errorf("node credential encryption key is unavailable")
	}
	key := sha256.Sum256(append([]byte("aseman/credentials/v1\x00"), raw...))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// SealSecret encrypts a credential with AES-256-GCM and binds it to its record.
func SealSecret(plain, master, context string) (string, error) {
	gcm, err := secretCipher(master)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	sealed := gcm.Seal(nonce, nonce, []byte(plain), []byte(context))
	return SecretPrefix + base64.RawStdEncoding.EncodeToString(sealed), nil
}

// OpenSecret rejects unknown versions, tampered blobs and the wrong identity.
func OpenSecret(sealed, master, context string) (string, error) {
	if !strings.HasPrefix(sealed, SecretPrefix) {
		return "", fmt.Errorf("unsupported credential encryption format")
	}
	gcm, err := secretCipher(master)
	if err != nil {
		return "", err
	}
	b, err := base64.RawStdEncoding.DecodeString(strings.TrimPrefix(sealed, SecretPrefix))
	if err != nil || len(b) < gcm.NonceSize()+gcm.Overhead() {
		return "", fmt.Errorf("invalid encrypted credential")
	}
	plain, err := gcm.Open(nil, b[:gcm.NonceSize()], b[gcm.NonceSize():], []byte(context))
	if err != nil {
		return "", fmt.Errorf("credential decryption failed")
	}
	return string(plain), nil
}
