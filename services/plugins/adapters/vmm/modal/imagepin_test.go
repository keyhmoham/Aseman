package modal

import "testing"

func TestSplitImageRef(t *testing.T) {
	for ref, want := range map[string][3]string{
		"ghcr.io/acme/aseman-sandbox-computer:latest": {"ghcr.io", "acme/aseman-sandbox-computer", "latest"},
		"ghcr.io/acme/app":                {"ghcr.io", "acme/app", "latest"},
		"node:22-bookworm":                {"registry-1.docker.io", "library/node", "22-bookworm"},
		"aseman/sandbox-computer:latest": {"registry-1.docker.io", "aseman/sandbox-computer", "latest"},
		"localhost:5000/app:dev":          {"localhost:5000", "app", "dev"},
	} {
		host, repo, tag := splitImageRef(ref)
		if got := [3]string{host, repo, tag}; got != want {
			t.Errorf("%s: got %v, want %v", ref, got, want)
		}
	}
}

func TestPinImageLeavesDigestsAlone(t *testing.T) {
	ref := "ghcr.io/acme/app@sha256:abc"
	if got := pinImage(t.Context(), ref); got != ref {
		t.Fatalf("got %s", got)
	}
}
