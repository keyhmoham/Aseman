package tools

import (
	"testing"

	"github.com/aseman/aseman/internal/plugins/identity"
)

func TestBrokerHeadersNameTheCaller(t *testing.T) {
	actor, _ := identity.Parse("00000000000000010000000000000007")
	if got := actorHeader("user-{{actor}}", actor); got != "user-"+actor.String() {
		t.Fatalf("got %q", got)
	}
	if got := actorHeader("Bearer abc", actor); got != "Bearer abc" {
		t.Fatalf("headers without the placeholder are unchanged: %q", got)
	}
	for _, b := range brokers {
		found := false
		for _, v := range b.Headers {
			if v == actorPlaceholder {
				found = true
			}
		}
		if !found {
			t.Fatalf("%s must scope every call to its person", b.Name)
		}
	}
}
