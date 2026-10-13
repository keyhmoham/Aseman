package tools

import (
	"net/url"
	"reflect"
	"testing"
)

func TestResourceMetadataURLs(t *testing.T) {
	resource, _ := url.Parse("https://api.example.com/mcp")
	got := resourceMetadataURLs(resource, `Bearer resource_metadata="https://api.example.com/meta/mcp"`)
	want := []string{
		"https://api.example.com/meta/mcp",
		"https://api.example.com/.well-known/oauth-protected-resource/mcp",
		"https://api.example.com/.well-known/oauth-protected-resource",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
	root, _ := url.Parse("https://mcp.example.com/")
	if got := resourceMetadataURLs(root, ""); !reflect.DeepEqual(got, []string{"https://mcp.example.com/.well-known/oauth-protected-resource"}) {
		t.Fatalf("got %v", got)
	}
}

func TestAuthorizationMetadataURLs(t *testing.T) {
	got := authorizationMetadataURLs("https://id.example.com/auth/v1/")
	want := []string{
		"https://id.example.com/.well-known/oauth-authorization-server/auth/v1",
		"https://id.example.com/.well-known/openid-configuration/auth/v1",
		"https://id.example.com/auth/v1/.well-known/oauth-authorization-server",
		"https://id.example.com/auth/v1/.well-known/openid-configuration",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
	got = authorizationMetadataURLs("https://id.example.com", "https://x/y")
	want = []string{
		"https://id.example.com/.well-known/oauth-authorization-server",
		"https://id.example.com/.well-known/openid-configuration",
		"https://x/y",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
}

func TestTokenResponse(t *testing.T) {
	// The standard answer.
	token := tokenResponse([]byte(`{"access_token":"a","refresh_token":"r","expires_in":3600}`))
	if token["access_token"] != "a" || token["refresh_token"] != "r" {
		t.Fatalf("got %v", token)
	}
	if at := expiresAt(token); at == nil {
		t.Fatal("an expiry was given")
	}
	// A provider that answers as a form.
	token = tokenResponse([]byte("access_token=gho_x&scope=repo&token_type=bearer"))
	if token["access_token"] != "gho_x" {
		t.Fatalf("got %v", token)
	}
	if at := expiresAt(token); at != nil {
		t.Fatal("a token with no expiry does not lapse")
	}
	if at := expiresAt(map[string]any{"expires_in": "28800"}); at == nil {
		t.Fatal("an expiry sent as text counts")
	}
}

func TestSampleNeedsClient(t *testing.T) {
	if !sampleNeedsClient("https://api.githubcopilot.com/mcp/") {
		t.Fatal("GitHub needs a client an administrator creates")
	}
	if sampleNeedsClient("https://mcp.deepwiki.com/mcp") {
		t.Fatal("an open server needs none")
	}
}
