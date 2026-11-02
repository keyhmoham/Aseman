package llm

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	llmprovider "github.com/aseman/aseman/plugins/actions/llm/models"
)

func TestOpenAITranscribePostsMultipart(t *testing.T) {
	var gotPath, gotAuth, gotType string
	var gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotAuth, gotType = r.URL.Path, r.Header.Get("Authorization"), r.Header.Get("Content-Type")
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"text":"hello world","duration":1.5}`))
	}))
	defer srv.Close()

	p := &llmprovider.Provider{BaseURL: srv.URL + "/v1", APIKey: "k", Kind: llmprovider.KindOpenAI}
	text, sec, err := openAITranscribe(context.Background(), p, "whisper-1", []byte("RIFF...."), "audio/wav")
	if err != nil {
		t.Fatal(err)
	}
	if text != "hello world" || sec != 1.5 {
		t.Fatalf("%q %v", text, sec)
	}
	if gotPath != "/v1/audio/transcriptions" || gotAuth != "Bearer k" || !strings.Contains(gotType, "multipart/") {
		t.Fatalf("request %s %s %s", gotPath, gotAuth, gotType)
	}
	if !strings.Contains(gotBody, `name="model"`) || !strings.Contains(gotBody, "whisper-1") {
		t.Fatalf("body %q", gotBody)
	}
}
