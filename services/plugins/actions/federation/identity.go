package federation

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/internal/plugins/module"
	"github.com/tradera/tradera/pkg/crypto"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/pkg/logger"
	"github.com/tradera/tradera/plugins/config"
)

// resolveNodeIdentity determines the node id and keypair. A node with no id on
// its first run is allocated a timestamp-derived id: the central node allocates
// it when configured with a central_url, or the node self-allocates when it IS
// the central node. The id and key are persisted across restarts.
func resolveNodeIdentity(ctx context.Context, cfg *dconfig.Config, log *logger.Logger) (id, privHex, pubHex string, central map[string]any, err error) {
	if cfg.Node.ID != "" {
		privHex, pubHex, err = loadOrCreateKey(cfg, log)
		return cfg.Node.ID, privHex, pubHex, nil, err
	}
	if b, rerr := os.ReadFile(filepath.Join("data", "node-id")); rerr == nil {
		id = strings.TrimSpace(string(b))
		if id != "" && len(id) == identity.HexLength {
			cfg.Node.ID = id
			privHex, pubHex, err = loadOrCreateKey(cfg, log)
			central = loadCentralInfo()
			return id, privHex, pubHex, central, err
		}
	}
	// First run: generate the keypair first (needed for allocation).
	kp, gerr := crypto.Generate()
	if gerr != nil {
		return "", "", "", nil, errs.Wrap(errs.CodeInternal, gerr, "generate node key")
	}
	if cfg.Node.Central {
		nid, nerr := identity.GenerateNodeID(time.Now())
		if nerr != nil {
			return "", "", "", nil, nerr
		}
		id = nid.String()
	} else {
		if cfg.Node.CentralURL == "" {
			return "", "", "", nil, errs.New(errs.CodeInvalidArgument,
				"no node.id configured and no node.central_url to allocate one")
		}
		var cerr error
		central, cerr = allocateNodeID(ctx, cfg.Node.CentralURL, kp.PublicHex(), cfg.Node.URL, cfg.Node.Name)
		if cerr != nil {
			return "", "", "", nil, cerr
		}
		allocated, _ := central["allocated_node_id"].(string)
		if allocated == "" {
			return "", "", "", nil, errs.New(errs.CodeFederation, "central returned no node_id")
		}
		id = allocated
	}
	cfg.Node.ID = id
	privHex, pubHex = kp.PrivateHex(), kp.PublicHex()
	_ = os.MkdirAll(filepath.Join("data"), 0o700)
	_ = os.WriteFile(filepath.Join("data", "node-id"), []byte(id), 0o600)
	_ = os.WriteFile(filepath.Join("data", "node-"+id+".key"), []byte(privHex), 0o600)
	if central != nil {
		saveCentralInfo(central)
	}
	log.Info("node identity allocated", "node_id", id, "central_allocated", !cfg.Node.Central)
	return id, privHex, pubHex, central, nil
}

// centralInfoFile persists the central peer discovered during bootstrap so it
// is re-registered after restarts (e.g. with an in-memory database).
const centralInfoFile = "data/node-central.json"

func saveCentralInfo(c map[string]any) {
	b, _ := json.Marshal(c)
	_ = os.WriteFile(centralInfoFile, b, 0o600)
}

func loadCentralInfo() map[string]any {
	b, err := os.ReadFile(centralInfoFile)
	if err != nil {
		return nil
	}
	out := map[string]any{}
	if json.Unmarshal(b, &out) != nil {
		return nil
	}
	return out
}

// loadOrCreateKey loads the persisted key or generates one.
func loadOrCreateKey(cfg *dconfig.Config, log *logger.Logger) (string, string, error) {
	if cfg.Node.PrivateKey != "" {
		pub, err := pubFromPriv(cfg.Node.PrivateKey)
		if err != nil {
			return "", "", errs.Wrap(errs.CodeInvalidArgument, err, "invalid node.private_key")
		}
		return cfg.Node.PrivateKey, pub, nil
	}
	keyPath := filepath.Join("data", "node-"+cfg.Node.ID+".key")
	if b, rerr := os.ReadFile(keyPath); rerr == nil {
		existing := strings.TrimSpace(string(b))
		if existing != "" {
			pub, err := pubFromPriv(existing)
			if err != nil {
				return "", "", errs.Wrap(errs.CodeInternal, err, "invalid persisted node key")
			}
			return existing, pub, nil
		}
	}
	kp, gerr := crypto.Generate()
	if gerr != nil {
		return "", "", errs.Wrap(errs.CodeInternal, gerr, "generate node key")
	}
	if err := os.MkdirAll(filepath.Dir(keyPath), 0o700); err != nil {
		return "", "", err
	}
	if err := os.WriteFile(keyPath, []byte(kp.PrivateHex()), 0o600); err != nil {
		return "", "", err
	}
	log.Info("generated node identity key", "path", keyPath, "node", cfg.Node.ID)
	return kp.PrivateHex(), kp.PublicHex(), nil
}

// allocateNodeID requests a timestamp-derived node id from the central node
// and returns the central node's own info for peer registration.
func allocateNodeID(ctx context.Context, centralURL, pubKey, url, name string) (map[string]any, error) {
	body, _ := json.Marshal(map[string]any{
		"public_key": pubKey, "url": url, "name": name,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		strings.TrimRight(centralURL, "/")+"/v1/federation/node_allocate", bytes.NewReader(body))
	if err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "build allocate request")
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "allocate node id from central")
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "read allocate response")
	}
	if resp.StatusCode >= 400 {
		return nil, errs.New(errs.CodeFederation, "central allocation failed: "+string(b))
	}
	var out struct {
		NodeID  string         `json:"node_id"`
		Central map[string]any `json:"central"`
	}
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, errs.Wrap(errs.CodeFederation, err, "decode allocate response")
	}
	if out.NodeID == "" {
		return nil, errs.New(errs.CodeFederation, "central returned no node_id")
	}
	if out.Central == nil {
		out.Central = map[string]any{}
	}
	out.Central["allocated_node_id"] = out.NodeID
	return out.Central, nil
}

// pubFromPriv derives the public key hex from a private key hex.
func pubFromPriv(privHex string) (string, error) {
	priv, err := hex.DecodeString(privHex)
	if err != nil || len(priv) != ed25519.PrivateKeySize {
		return "", fmt.Errorf("bad private key length")
	}
	return hex.EncodeToString(ed25519.PrivateKey(priv).Public().(ed25519.PublicKey)), nil
}

type namespacePlugin struct{ *module.Plugin }

func (p *namespacePlugin) PrepareIdentity(ctx context.Context, config map[string]any, log *logger.Logger) (api.NodeIdentity, error) {
	var cfg dconfig.Config
	data, err := json.Marshal(config)
	if err != nil {
		return api.NodeIdentity{}, err
	}
	if err = json.Unmarshal(data, &cfg); err != nil {
		return api.NodeIdentity{}, err
	}
	id, priv, pub, central, err := resolveNodeIdentity(ctx, &cfg, log)
	if err != nil {
		return api.NodeIdentity{}, err
	}
	env := make(map[string]string)
	for _, key := range []string{"node_id", "url", "public_key"} {
		if v, ok := central[key].(string); ok {
			target := map[string]string{"node_id": "central_node_id", "url": "central_node_url", "public_key": "central_node_pub"}[key]
			env[target] = v
		}
	}
	return api.NodeIdentity{ID: id, PrivateKey: priv, PublicKey: pub, Env: env}, nil
}
