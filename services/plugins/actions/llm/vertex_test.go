package llm

import (
	"context"
	"testing"
)

func TestResolveVertexURL(t *testing.T) {
	ctx := context.Background()

	raw := "https://aiplatform.googleapis.com/v1/projects/{project_id}/locations/{location}/endpoints/openapi"
	t.Setenv("ASEMAN_VERTEX_LOCATION", "us-east1")
	t.Setenv("ASEMAN_VERTEX_PROJECT", "my-test-proj")

	resolved := ResolveVertexURL(ctx, raw, "dummy-key")
	expected := "https://aiplatform.googleapis.com/v1/projects/my-test-proj/locations/us-east1/endpoints/openapi"
	if resolved != expected {
		t.Fatalf("expected %q, got %q", expected, resolved)
	}

	// Test cached discovery
	gcpProjectCache.Store("cached-api-key", "discovered-proj-123")
	t.Setenv("ASEMAN_VERTEX_PROJECT", "")
	t.Setenv("GOOGLE_CLOUD_PROJECT", "")
	t.Setenv("GCP_PROJECT", "")
	resolvedCached := ResolveVertexURL(ctx, raw, "cached-api-key")
	expectedCached := "https://aiplatform.googleapis.com/v1/projects/discovered-proj-123/locations/us-east1/endpoints/openapi"
	if resolvedCached != expectedCached {
		t.Fatalf("expected %q, got %q", expectedCached, resolvedCached)
	}
}
