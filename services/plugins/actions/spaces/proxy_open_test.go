package spaces

import (
	"strings"
	"testing"

	"github.com/tradera/tradera/internal/plugins/entity"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/spaces/models/proxy"
)

// A preview keeps the command that starts its service, so it can be brought
// back after the project's computer has slept.
func TestPreviewRemembersHowItIsStarted(t *testing.T) {
	s, ctx := fileToolHarness(t)
	owner := idFromHex(t, "00000000000000010000000000000001")
	sp, err := s.CreateSpace(ctx, owner, "cafe", "")
	if err != nil {
		t.Fatal(err)
	}
	id, _ := identity.New(s.K.NodeID())
	p := &proxy.Proxy{Entity: entity.Entity{ID: id}, SpaceID: sp.ID, Port: 3000}
	if got := s.previewStart(ctx, p); got != "" {
		t.Fatalf("a preview published without a command has none: %q", got)
	}
	if err := s.setPreviewStart(ctx, p, "  npm --prefix /workspace/site start -- -p 3000  "); err != nil {
		t.Fatal(err)
	}
	if got := s.previewStart(ctx, p); got != "npm --prefix /workspace/site start -- -p 3000" {
		t.Fatalf("start command = %q", got)
	}
	// An empty command leaves what is saved alone; an absurdly long one is refused.
	if err := s.setPreviewStart(ctx, p, ""); err != nil || s.previewStart(ctx, p) == "" {
		t.Fatalf("an empty command cleared the saved one: %v", err)
	}
	if err := s.setPreviewStart(ctx, p, strings.Repeat("x", 2001)); err == nil {
		t.Fatal("an overlong command was accepted")
	}
	if got := shellQuote("it's"); got != `'it'\''s'` {
		t.Fatalf("quoting = %s", got)
	}
}
