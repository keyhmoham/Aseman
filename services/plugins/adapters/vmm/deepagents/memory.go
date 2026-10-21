package deepagents

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"io"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// MemoryDimension is the size of every vector in the agents' memory. OpenViking
// keeps one index of a fixed size, while embedding models differ (768, 1024,
// 1536, 3072 …): the node fits each model's vectors to it, so the admin can
// pick any embedding model. deploy/openviking/ov.conf declares the same size.
const MemoryDimension = 1536

// memoryTimeout bounds one model call of the memory server.
const memoryTimeout = 5 * time.Minute

// serveMemoryChat is the chat model of the agents' memory server: OpenViking
// reads finished conversations with it and writes down what is worth
// remembering. It answers as OpenAI's chat completions, with the model the
// admin picked (Admin → Memory models), whatever model the request names.
//
//	POST {gateway}/memory/chat/completions   (Bearer: the OpenViking root key)
//
// 409 memory_model_unset means the admin has not picked the model.
func (a *Adapter) serveMemoryChat(ctx context.Context, req *network.Request) (*network.Response, error) {
	if resp := a.memoryCaller(req); resp != nil {
		return resp, nil
	}
	provider, err := a.platform.ResolveMemoryChat(ctx)
	if err != nil {
		return memoryUnset(err), nil
	}
	var body map[string]any
	if err := json.Unmarshal(req.Body, &body); err != nil {
		return openAIError(400, "invalid request body"), nil
	}
	stream, _ := body["stream"].(bool)
	if stream {
		// The last chunk then says what the call used, for the bill.
		opts, _ := body["stream_options"].(map[string]any)
		if opts == nil {
			opts = map[string]any{}
		}
		opts["include_usage"] = true
		body["stream_options"] = opts
	}
	callCtx, cancel := context.WithTimeout(ctx, memoryTimeout)
	defer cancel()
	up, err := providerRequest(callCtx, provider, "/chat/completions", body)
	if err != nil {
		return openAIError(500, err.Error()), nil
	}
	if stream {
		up.Header.Set("Accept", "text/event-stream")
	}
	return a.forwardMemory(up, func(data []byte) ([]byte, error) {
		in, out := parseUsage(data, stream)
		a.meterMemory(req.Header, provider, in, out)
		return data, nil
	})
}

// serveMemoryEmbeddings is the embedding model of the agents' memory server:
// OpenAI's embeddings endpoint with the model the admin picked, every vector
// fitted to MemoryDimension.
//
//	POST {gateway}/memory/embeddings   (Bearer: the OpenViking root key)
func (a *Adapter) serveMemoryEmbeddings(ctx context.Context, req *network.Request) (*network.Response, error) {
	if resp := a.memoryCaller(req); resp != nil {
		return resp, nil
	}
	provider, err := a.platform.ResolveMemoryEmbedding(ctx)
	if err != nil {
		return memoryUnset(err), nil
	}
	var body map[string]any
	if err := json.Unmarshal(req.Body, &body); err != nil || body["input"] == nil {
		return openAIError(400, "an embedding request needs an input"), nil
	}
	// The caller's OpenAI client asks for base64 unless told otherwise; the
	// provider is asked for plain numbers (every provider has those) and the
	// answer is given back in the form asked for.
	format, _ := body["encoding_format"].(string)
	delete(body, "encoding_format")
	delete(body, "dimensions")
	if shortens(provider) {
		body["dimensions"] = MemoryDimension
	}
	estimate := estimateTokens(body["input"])
	callCtx, cancel := context.WithTimeout(ctx, memoryTimeout)
	defer cancel()
	up, err := providerRequest(callCtx, provider, "/embeddings", body)
	if err != nil {
		return openAIError(500, err.Error()), nil
	}
	return a.forwardMemory(up, func(data []byte) ([]byte, error) {
		out, err := fitEmbeddings(data, format == "base64")
		if err != nil {
			return nil, err
		}
		in, _ := parseUsage(data, false)
		if in == 0 {
			in = estimate // a provider that does not say: about four characters a token
		}
		a.meterMemory(req.Header, provider, in, 0)
		return out, nil
	})
}

// estimateTokens is about how many tokens an embedding input holds.
func estimateTokens(input any) int64 {
	var chars int
	switch v := input.(type) {
	case string:
		chars = len(v)
	case []any:
		for _, item := range v {
			if s, ok := item.(string); ok {
				chars += len(s)
			} else {
				chars += 4 // a pre-tokenized input: one token an item
			}
		}
	}
	return int64((chars + 3) / 4)
}

// memoryCaller lets in only the memory server: it holds the OpenViking root
// key, which the node has too. Nil means the caller may go on.
func (a *Adapter) memoryCaller(req *network.Request) *network.Response {
	if a.memoryKey == "" {
		return openAIError(503, "the agents' memory server is not configured on this node")
	}
	if subtle.ConstantTimeCompare([]byte(bearer(req.Header)), []byte(a.memoryKey)) != 1 {
		return openAIError(401, "invalid memory server key")
	}
	if a.unpaid(req.Header) {
		return openAIError(http.StatusPaymentRequired, "this project cannot pay for its agents' memory now (wallet or budget)")
	}
	return nil
}

func memoryUnset(err error) *network.Response {
	return jsonResponse(http.StatusConflict, map[string]any{"error": map[string]any{
		"message": err.Error() + ". Pick it under Admin → Memory models.", "type": "aseman_error", "code": "memory_model_unset",
	}})
}

// forwardMemory sends a request to the provider and answers with its
// response, passed through done (which meters it and may rewrite it) when the
// provider succeeded.
func (a *Adapter) forwardMemory(up *http.Request, done func([]byte) ([]byte, error)) (*network.Response, error) {
	resp, err := a.client.Do(up)
	if err != nil {
		return openAIError(502, "LLM provider unreachable: "+err.Error()), nil
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	if err != nil {
		return openAIError(502, "LLM provider response failed: "+err.Error()), nil
	}
	if resp.StatusCode < 300 {
		if data, err = done(data); err != nil {
			return openAIError(502, "LLM provider answered without embeddings: "+err.Error()), nil
		}
	}
	ct := resp.Header.Get("Content-Type")
	if ct == "" {
		ct = "application/json"
	}
	return &network.Response{Status: resp.StatusCode, Header: map[string]string{"Content-Type": ct}, Body: data}, nil
}

// shortens reports whether the provider's model makes vectors of a requested
// size itself (OpenAI's text-embedding-3 family, also through gateways): they
// are trained for it, so this is better than cutting them.
func shortens(p vmm.ProviderConfig) bool {
	model := strings.ToLower(p.Model)
	return strings.Contains(model, "text-embedding-3")
}

// fitEmbeddings fits every vector of an embeddings response to
// MemoryDimension: a shorter one is padded with zeros (which keeps every
// similarity as it was), a longer one is cut and scaled back to unit length.
func fitEmbeddings(data []byte, asBase64 bool) ([]byte, error) {
	var out map[string]any
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, err
	}
	rows, _ := out["data"].([]any)
	if len(rows) == 0 {
		return nil, errNoEmbeddings
	}
	for _, r := range rows {
		row, _ := r.(map[string]any)
		if row == nil {
			return nil, errNoEmbeddings
		}
		vector, err := decodeVector(row["embedding"])
		if err != nil {
			return nil, err
		}
		vector = fitVector(vector, MemoryDimension)
		if asBase64 {
			row["embedding"] = encodeVector(vector)
		} else {
			row["embedding"] = vector
		}
	}
	return json.Marshal(out)
}

type embeddingError string

func (e embeddingError) Error() string { return string(e) }

const errNoEmbeddings = embeddingError("no embeddings in the response")

func decodeVector(v any) ([]float64, error) {
	switch x := v.(type) {
	case []any:
		out := make([]float64, len(x))
		for i, n := range x {
			f, ok := n.(float64)
			if !ok {
				return nil, embeddingError("an embedding holds something other than numbers")
			}
			out[i] = f
		}
		return out, nil
	case string: // base64 of little-endian float32s
		raw, err := base64.StdEncoding.DecodeString(x)
		if err != nil || len(raw)%4 != 0 {
			return nil, embeddingError("an embedding is not valid base64 float32s")
		}
		out := make([]float64, len(raw)/4)
		for i := range out {
			out[i] = float64(math.Float32frombits(binary.LittleEndian.Uint32(raw[i*4:])))
		}
		return out, nil
	}
	return nil, errNoEmbeddings
}

func encodeVector(v []float64) string {
	raw := make([]byte, len(v)*4)
	for i, f := range v {
		binary.LittleEndian.PutUint32(raw[i*4:], math.Float32bits(float32(f)))
	}
	return base64.StdEncoding.EncodeToString(raw)
}

func fitVector(v []float64, size int) []float64 {
	if len(v) == size {
		return v
	}
	if len(v) < size {
		return append(v, make([]float64, size-len(v))...)
	}
	v = v[:size]
	var norm float64
	for _, f := range v {
		norm += f * f
	}
	if norm = math.Sqrt(norm); norm > 0 {
		for i := range v {
			v[i] /= norm
		}
	}
	return v
}
