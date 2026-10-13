// Package idutil provides randomness and encoding helpers for identifiers.
package idutil

import (
	"crypto/rand"
	"encoding/hex"
	"math/big"
)

// RandomHex returns n bytes of cryptographically secure random data as hex.
func RandomHex(nBytes int) (string, error) {
	buf := make([]byte, nBytes)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

// RandomString returns a random alphanumeric string of length n.
func RandomString(n int) (string, error) {
	const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	pool := big.NewInt(int64(len(alphabet)))
	out := make([]byte, n)
	for i := range out {
		idx, err := rand.Int(rand.Reader, pool)
		if err != nil {
			return "", err
		}
		out[i] = alphabet[idx.Int64()]
	}
	return string(out), nil
}
