package mediahost

import (
	"testing"
)

func TestNormalizeAndGuard(t *testing.T) {
	got, err := NormalizeURL("HTTPS://CDN.Example/a.png#x")
	if err != nil || got != "https://cdn.example/a.png" {
		t.Fatalf("normalize: %q %v", got, err)
	}
	for _, bad := range []string{
		"http://127.0.0.1/x.png",
		"http://localhost/x.png",
		"http://169.254.169.254/latest",
		"ftp://cdn.example/a.png",
		"/v1/files/abc/content",
	} {
		if _, err := ParsePublicURL(bad); err == nil {
			t.Fatalf("expected reject %q", bad)
		}
	}
}

func TestExternalURLsAndRewrite(t *testing.T) {
	body := "Hello\n\n:::image https://cdn.example/a.png\n\n![x](https://cdn.example/b.jpg)\n\n:::video https://cdn.example/c.mp4\n"
	urls := ExternalURLs(body)
	if len(urls) != 3 {
		t.Fatalf("urls: %v", urls)
	}
	refs := map[string]string{
		"https://cdn.example/a.png": "/v1/files/00000000000000010000000000000001/content",
		"https://cdn.example/b.jpg": "/v1/files/00000000000000010000000000000002/content",
		"https://cdn.example/c.mp4": "/v1/files/00000000000000010000000000000003/content",
	}
	got := Rewrite(body, refs)
	for _, want := range []string{
		":::image /v1/files/00000000000000010000000000000001/content",
		"![x](/v1/files/00000000000000010000000000000002/content)",
		":::video /v1/files/00000000000000010000000000000003/content",
	} {
		if !contains(got, want) {
			t.Fatalf("missing %q in\n%s", want, got)
		}
	}
	if contains(got, "https://cdn.example") {
		t.Fatalf("remote URLs remain:\n%s", got)
	}
}

func TestAllowedMIME(t *testing.T) {
	if !AllowedMIME("image/png") || !AllowedMIME("video/mp4") || !AllowedMIME("audio/mpeg") {
		t.Fatal("media mimes")
	}
	if AllowedMIME("text/html") || AllowedMIME("application/javascript") {
		t.Fatal("dangerous mimes")
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(sub) == 0 ||
		(len(s) > 0 && (func() bool {
			for i := 0; i+len(sub) <= len(s); i++ {
				if s[i:i+len(sub)] == sub {
					return true
				}
			}
			return false
		})()))
}
