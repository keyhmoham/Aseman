package deepagents

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/tradera/tradera/plugins/adapters/network/ports"
	"github.com/tradera/tradera/plugins/adapters/vmm/ports"
)

func memoryCall(t *testing.T, serve func(context.Context, *network.Request) (*network.Response, error), key, body string) *network.Response {
	t.Helper()
	resp, err := serve(context.Background(), &network.Request{Header: map[string]string{"Authorization": "Bearer " + key}, Body: []byte(body)})
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

// provider is a fake OpenAI-compatible provider recording what it was asked.
func provider(t *testing.T, answer func(path string, body map[string]any) string) (*httptest.Server, *map[string]any, *string) {
	got, auth := map[string]any{}, ""
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		got = map[string]any{}
		_ = json.Unmarshal(raw, &got)
		auth = r.Header.Get("Authorization")
		_, _ = w.Write([]byte(answer(r.URL.Path, got)))
	}))
	t.Cleanup(srv.Close)
	return srv, &got, &auth
}

func TestMemoryModelsAreOnlyForTheMemoryServer(t *testing.T) {
	a, _, _ := newTestAdapter(t)
	a.platform = fakePlatform{memoryChat: &vmm.ProviderConfig{Model: "m"}}
	if resp := memoryCall(t, a.serveMemoryChat, "anything", `{}`); resp.Status != 503 {
		t.Fatalf("no key on the node: no memory models (%d)", resp.Status)
	}
	a.memoryKey = "root-key"
	if resp := memoryCall(t, a.serveMemoryChat, "wrong", `{}`); resp.Status != 401 {
		t.Fatalf("a wrong key is refused (%d)", resp.Status)
	}
	a.platform = fakePlatform{}
	if resp := memoryCall(t, a.serveMemoryEmbeddings, "root-key", `{"input":"x"}`); resp.Status != 409 ||
		!json.Valid(resp.Body) || !strings.Contains(string(resp.Body), "memory_model_unset") {
		t.Fatalf("an unset model says so: %d %s", resp.Status, resp.Body)
	}
}

func TestMemoryChatUsesTheAdminsModel(t *testing.T) {
	srv, got, auth := provider(t, func(path string, _ map[string]any) string {
		return `{"choices":[{"message":{"role":"assistant","content":"remembered"}}],"usage":{"prompt_tokens":3,"completion_tokens":1}}`
	})
	a, _, _ := newTestAdapter(t)
	a.memoryKey = "root-key"
	a.platform = fakePlatform{memoryChat: &vmm.ProviderConfig{BaseURL: srv.URL + "/v1", APIKey: "sk-admin", Model: "gpt-5.4-mini"}}
	resp := memoryCall(t, a.serveMemoryChat, "root-key", `{"model":"tradera-memory","messages":[{"role":"user","content":"hi"}]}`)
	if resp.Status != 200 || !strings.Contains(string(resp.Body), "remembered") {
		t.Fatalf("%d %s", resp.Status, resp.Body)
	}
	if (*got)["model"] != "gpt-5.4-mini" || *auth != "Bearer sk-admin" {
		t.Fatalf("upstream got model=%v auth=%s", (*got)["model"], *auth)
	}
}

func TestMemoryEmbeddingsAreFittedToTheIndex(t *testing.T) {
	short := make([]float64, 768)
	short[0] = 1
	srv, got, _ := provider(t, func(path string, _ map[string]any) string {
		out, _ := json.Marshal(map[string]any{"data": []any{map[string]any{"index": 0, "embedding": short}}, "model": "nomic"})
		return string(out)
	})
	a, _, _ := newTestAdapter(t)
	a.memoryKey = "root-key"
	a.platform = fakePlatform{memoryEmbedding: &vmm.ProviderConfig{BaseURL: srv.URL, Model: "nomic-embed-text"}}

	// As plain numbers: padded to the index size.
	resp := memoryCall(t, a.serveMemoryEmbeddings, "root-key", `{"model":"x","input":["hello"],"dimensions":1536,"encoding_format":"float"}`)
	var out struct {
		Data []struct {
			Embedding json.RawMessage `json:"embedding"`
		} `json:"data"`
	}
	if resp.Status != 200 || json.Unmarshal(resp.Body, &out) != nil || len(out.Data) != 1 {
		t.Fatalf("%d %s", resp.Status, resp.Body)
	}
	var vector []float64
	if err := json.Unmarshal(out.Data[0].Embedding, &vector); err != nil || len(vector) != MemoryDimension || vector[0] != 1 || vector[1535] != 0 {
		t.Fatalf("padded vector: %d %v", len(vector), err)
	}
	if (*got)["model"] != "nomic-embed-text" || (*got)["dimensions"] != nil || (*got)["encoding_format"] != nil {
		t.Fatalf("a model that cannot shorten is not asked to: %v", *got)
	}

	// As base64 (what OpenAI's client asks for by default).
	resp = memoryCall(t, a.serveMemoryEmbeddings, "root-key", `{"input":"hello","encoding_format":"base64"}`)
	if json.Unmarshal(resp.Body, &out) != nil {
		t.Fatalf("%s", resp.Body)
	}
	var encoded string
	if err := json.Unmarshal(out.Data[0].Embedding, &encoded); err != nil {
		t.Fatalf("base64 asked, base64 given: %s", out.Data[0].Embedding)
	}
	raw, _ := base64.StdEncoding.DecodeString(encoded)
	if len(raw) != MemoryDimension*4 || math.Float32frombits(binary.LittleEndian.Uint32(raw)) != 1 {
		t.Fatalf("base64 vector of %d bytes", len(raw))
	}

	// OpenAI's text-embedding-3 models are asked for the size itself.
	a.platform = fakePlatform{memoryEmbedding: &vmm.ProviderConfig{BaseURL: srv.URL, Model: "text-embedding-3-large"}}
	memoryCall(t, a.serveMemoryEmbeddings, "root-key", `{"input":"hello"}`)
	if (*got)["dimensions"] != float64(MemoryDimension) {
		t.Fatalf("text-embedding-3 is asked for %v dimensions", (*got)["dimensions"])
	}
}

func TestLongerVectorsAreCutBackToUnitLength(t *testing.T) {
	v := make([]float64, 3072)
	for i := range v {
		v[i] = 1 / math.Sqrt(3072)
	}
	fitted := fitVector(v, MemoryDimension)
	var norm float64
	for _, f := range fitted {
		norm += f * f
	}
	if len(fitted) != MemoryDimension || math.Abs(norm-1) > 1e-9 {
		t.Fatalf("len %d norm %v", len(fitted), norm)
	}
}

// The memory server's config declares the vector size the node fits vectors
// to, and calls the node's memory endpoints.
func TestTheMemoryServerConfigMatchesTheNode(t *testing.T) {
	raw, err := os.ReadFile("../../../../../deploy/openviking/ov.conf")
	if err != nil {
		t.Skip("deploy/openviking/ov.conf is not in this checkout")
	}
	var conf struct {
		Embedding struct {
			Dense struct {
				Dimension int    `json:"dimension"`
				APIBase   string `json:"api_base"`
			} `json:"dense"`
		} `json:"embedding"`
		VLM struct {
			APIBase string `json:"api_base"`
		} `json:"vlm"`
	}
	if err := json.Unmarshal(raw, &conf); err != nil {
		t.Fatal(err)
	}
	if conf.Embedding.Dense.Dimension != MemoryDimension {
		t.Fatalf("ov.conf dimension %d, node fits vectors to %d", conf.Embedding.Dense.Dimension, MemoryDimension)
	}
	for _, base := range []string{conf.Embedding.Dense.APIBase, conf.VLM.APIBase} {
		if !strings.HasSuffix(base, gatewayPrefix+"/memory") {
			t.Fatalf("ov.conf calls %s, not the node's memory endpoints", base)
		}
	}
}
