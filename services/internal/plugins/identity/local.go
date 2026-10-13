package identity

import (
	"crypto/ed25519"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/tradera/tradera/pkg/crypto"
	"github.com/tradera/tradera/pkg/errs"
)

// LocalIdentity supplies a standalone host identity when no plugin provisions one.
type LocalIdentity struct {
	ID, PrivateKey, PublicKey string
	Env                       map[string]string
}

func Local(id, privateKey string) (LocalIdentity, error) {
	if id == "" {
		if stored, err := os.ReadFile("data/node-id"); err == nil {
			id = strings.TrimSpace(string(stored))
		}
	}
	if id == "" {
		node, err := GenerateNodeID(time.Now())
		if err != nil {
			return LocalIdentity{}, err
		}
		id = node.String()
	}
	if _, err := NodeOf(id); err != nil {
		return LocalIdentity{}, err
	}
	path := filepath.Join("data", "node-"+id+".key")
	if privateKey == "" {
		if stored, err := os.ReadFile(path); err == nil {
			privateKey = strings.TrimSpace(string(stored))
		}
	}
	if privateKey == "" {
		keys, err := crypto.Generate()
		if err != nil {
			return LocalIdentity{}, err
		}
		privateKey = keys.PrivateHex()
	}
	key, err := hex.DecodeString(privateKey)
	if err != nil || len(key) != ed25519.PrivateKeySize {
		return LocalIdentity{}, errs.InvalidArgument("invalid node private key")
	}
	if err := os.MkdirAll("data", 0700); err != nil {
		return LocalIdentity{}, err
	}
	if err := os.WriteFile("data/node-id", []byte(id), 0600); err != nil {
		return LocalIdentity{}, err
	}
	if err := os.WriteFile(path, []byte(privateKey), 0600); err != nil {
		return LocalIdentity{}, err
	}
	return LocalIdentity{ID: id, PrivateKey: privateKey, PublicKey: hex.EncodeToString(ed25519.PrivateKey(key).Public().(ed25519.PublicKey))}, nil
}
