// Package node defines the federation node registry. Each node advertises its
// node id, endpoints and public key so the mesh can route cross-node requests.
package node

import (
	"time"

	"github.com/aseman/aseman/internal/plugins/identity"
)

// Status of a peer node.
type Status string

const (
	StatusOnline  Status = "online"
	StatusOffline Status = "offline"
)

// Node is a peer in the federated mesh.
type Node struct {
	ID        identity.NodeID `db:"id" json:"id"` // the 64-bit node id (hex key)
	URL       string          `db:"url" json:"url"`
	PublicKey string          `db:"public_key" json:"public_key"`
	Status    Status          `db:"status" json:"status"`
	LastSeen  time.Time       `db:"last_seen" json:"last_seen,omitempty"`
	IsCentral bool            `db:"is_central" json:"is_central"` // holds the primary ledger
}
