// Package identity implements the aseman universal identifier.
//
// Every entity in the federated network is addressed by a universal ID made of
// two fixed 64-bit parts, each rendered as 16 lowercase hex characters:
//
//	<node id (16 hex)> + <entity id (16 hex)>  =>  32 hex characters
//
// The node part points to the federation node that owns the entity; the entity
// part is unique within that node's database table. This lets any node resolve
// the origin of an entity and proxy operations to the owning node.
package identity

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/idutil"
)

const (
	// HexLength is the fixed length of each part in hex characters.
	HexLength = 16
	// UniversalLength is the total length of a universal ID string.
	UniversalLength = HexLength * 2
)

// NodeID is the fixed 64-bit identifier of a federation node.
type NodeID uint64

// String renders the node id as 16 hex characters.
func (n NodeID) String() string { return fmt.Sprintf("%016x", uint64(n)) }

// EntityID is the fixed 64-bit identifier of an entity within a node table.
type EntityID uint64

// ID is a universal identifier: node part + entity part.
type ID struct {
	Node   NodeID
	Entity EntityID
}

// String renders the universal ID as 32 hex characters.
func (id ID) String() string {
	return fmt.Sprintf("%016x%016x", uint64(id.Node), uint64(id.Entity))
}

// NodeString renders only the node part (16 hex characters).
func (id ID) NodeString() string { return fmt.Sprintf("%016x", uint64(id.Node)) }

// EntityString renders only the entity part (16 hex characters).
func (id ID) EntityString() string { return fmt.Sprintf("%016x", uint64(id.Entity)) }

// IsZero reports whether the ID is unset.
func (id ID) IsZero() bool { return id.Node == 0 && id.Entity == 0 }

// NodeOf extracts the node part of a universal ID string or a bare node id
// string (16 hex) without full parsing.
func NodeOf(s string) (NodeID, error) {
	switch len(s) {
	case UniversalLength:
		n, err := parseHex(s[:HexLength])
		if err != nil {
			return 0, errs.Wrap(errs.CodeInvalidArgument, err, "invalid node part")
		}
		return NodeID(n), nil
	case HexLength:
		n, err := parseHex(s)
		if err != nil {
			return 0, errs.Wrap(errs.CodeInvalidArgument, err, "invalid node id")
		}
		return NodeID(n), nil
	default:
		return 0, errs.InvalidArgument("node id must be 16 hex characters")
	}
}

// MatchesNode reports whether the given universal id string belongs to node.
func MatchesNode(s string, node NodeID) bool {
	n, err := NodeOf(s)
	return err == nil && n == node
}

// Parse parses a 32-hex universal ID string.
func Parse(s string) (ID, error) {
	s = strings.TrimSpace(s)
	if len(s) != UniversalLength {
		return ID{}, errs.InvalidArgument(
			fmt.Sprintf("universal id must be %d hex characters, got %q", UniversalLength, s))
	}
	node, err := parseHex(s[:HexLength])
	if err != nil {
		return ID{}, errs.Wrap(errs.CodeInvalidArgument, err, "invalid node part")
	}
	entity, err := parseHex(s[HexLength:])
	if err != nil {
		return ID{}, errs.Wrap(errs.CodeInvalidArgument, err, "invalid entity part")
	}
	return ID{Node: NodeID(node), Entity: EntityID(entity)}, nil
}

// nodeIDEntropyBits is the number of low random bits mixed into a generated
// node id (the high bits are the unix-millisecond timestamp).
const nodeIDEntropyBits = 22

// GenerateNodeID allocates a 64-bit node id from the moment of allocation (not
// a counter). The high bits are the unix-millisecond timestamp (time-ordered);
// the low bits are random entropy, so simultaneous allocations cannot collide.
// Node ids are therefore timestamp-derived and unique per allocation.
func GenerateNodeID(now time.Time) (NodeID, error) {
	ms := uint64(now.UnixMilli())
	buf := make([]byte, 4)
	if _, err := rand.Read(buf); err != nil {
		return 0, errs.Wrap(errs.CodeInternal, err, "generate node id entropy")
	}
	entropy := (uint64(buf[0])<<24 | uint64(buf[1])<<16 | uint64(buf[2])<<8 | uint64(buf[3])) &
		((1 << nodeIDEntropyBits) - 1)
	return NodeID(ms<<nodeIDEntropyBits | entropy), nil
}

// MustParse parses a universal ID string and panics on failure.
func MustParse(s string) ID {
	id, err := Parse(s)
	if err != nil {
		panic(err)
	}
	return id
}

// New generates a fresh entity ID for the given node.
func New(node NodeID) (ID, error) {
	ent, err := idutil.RandomHex(8)
	if err != nil {
		return ID{}, errs.Wrap(errs.CodeInternal, err, "failed to generate entity id")
	}
	v, err := parseHex(ent)
	if err != nil {
		return ID{}, err
	}
	return ID{Node: node, Entity: EntityID(v)}, nil
}

func parseHex(s string) (uint64, error) {
	var v uint64
	if _, err := fmt.Sscanf(s, "%016x", &v); err != nil {
		return 0, fmt.Errorf("invalid hex %q", s)
	}
	return v, nil
}

// MarshalJSON renders the ID as its universal string form.
func (id ID) MarshalJSON() ([]byte, error) {
	return json.Marshal(id.String())
}

// UnmarshalJSON accepts either a plain universal id string.
func (id *ID) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	parsed, err := Parse(s)
	if err != nil {
		return err
	}
	*id = parsed
	return nil
}

// MarshalText implements encoding.TextMarshaler.
func (id ID) MarshalText() ([]byte, error) { return []byte(id.String()), nil }

// UnmarshalText implements encoding.TextUnmarshaler.
func (id *ID) UnmarshalText(b []byte) error {
	parsed, err := Parse(string(b))
	if err != nil {
		return err
	}
	*id = parsed
	return nil
}
