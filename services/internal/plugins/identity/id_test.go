package identity

import (
	"encoding/json"
	"testing"
	"time"
)

func TestIDStringRoundTrip(t *testing.T) {
	id := ID{Node: 0x0000000000000001, Entity: 0xabcdefabcdefabcd}
	s := id.String()
	if len(s) != UniversalLength {
		t.Fatalf("expected %d chars, got %d", UniversalLength, len(s))
	}
	parsed, err := Parse(s)
	if err != nil {
		t.Fatal(err)
	}
	if parsed != id {
		t.Fatalf("round trip mismatch: %v != %v", parsed, id)
	}
	if parsed.NodeString() != "0000000000000001" {
		t.Fatalf("bad node string: %s", parsed.NodeString())
	}
	if parsed.EntityString() != "abcdefabcdefabcd" {
		t.Fatalf("bad entity string: %s", parsed.EntityString())
	}
}

func TestParseErrors(t *testing.T) {
	for _, bad := range []string{"", "abc", "ffffffffffffffffffffffffffffffffffffffff", "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG"} {
		if _, err := Parse(bad); err == nil {
			t.Fatalf("expected error for %q", bad)
		}
	}
}

func TestJSONMarshal(t *testing.T) {
	id := MustParse("0000000000000001123456789abcdef0")
	b, err := json.Marshal(id)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != `"0000000000000001123456789abcdef0"` {
		t.Fatalf("bad json: %s", b)
	}
	var out ID
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	if out != id {
		t.Fatal("json round trip mismatch")
	}
}

func TestMatchesNode(t *testing.T) {
	if !MatchesNode("0000000000000001123456789abcdef0", 1) {
		t.Fatal("expected match")
	}
	if MatchesNode("0000000000000001123456789abcdef0", 2) {
		t.Fatal("expected no match")
	}
}

func TestNewUnique(t *testing.T) {
	a, _ := New(5)
	b, _ := New(5)
	if a == b {
		t.Fatal("expected distinct ids")
	}
	if a.Node != 5 || b.Node != 5 {
		t.Fatal("node part should be preserved")
	}
}

func TestGenerateNodeIDTimestampDerived(t *testing.T) {
	now := time.Now()
	a, err := GenerateNodeID(now)
	if err != nil {
		t.Fatal(err)
	}
	b, err := GenerateNodeID(now.Add(10 * time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	// Time-ordered: the later allocation is the larger id.
	if a >= b {
		t.Fatalf("expected time-ordered ids, got a=%d b=%d", a, b)
	}
	// Round trip through hex.
	parsed, err := NodeOf(a.String())
	if err != nil || parsed != a {
		t.Fatalf("node id round trip failed: %v != %v", parsed, a)
	}
	// The high bits encode the millisecond timestamp (not a tiny counter).
	if a < (1 << 40) {
		t.Fatalf("id too small for a timestamp-derived id: %d", a)
	}
}
