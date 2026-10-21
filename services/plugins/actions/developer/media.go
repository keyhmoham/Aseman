package developer

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/aseman/aseman/plugins/actions/llm/dto"
)

// Usage is what a call used, in the units it is charged by.
type Usage struct {
	TokensIn   int64
	TokensOut  int64
	Images     int64
	Seconds    float64
	Resolution string
	Characters int64
	Searches   int64
}

// costOf prices what a call used, in ledger units, rounded up: any priced use
// costs something.
func costOf(typ string, e Endpoint, u Usage) int64 {
	o := e.offering
	tokens := (float64(u.TokensIn)*o.InputPrice + float64(u.TokensOut)*o.OutputPrice) / 1e6
	var c float64
	switch typ {
	case TypeLanguage, TypeDecision:
		c = tokens
	case TypeEmbedding:
		c = float64(u.TokensIn) * o.InputPrice / 1e6
	case TypeImage:
		c = float64(u.Images)*o.PerImage + tokens
	case TypeVideo:
		c = u.Seconds * videoRate(o, u.Resolution)
	case TypeSpeech:
		c = float64(u.Characters) * o.PerCharacter
	case TypeTranscription:
		c = u.Seconds * o.PerSecond
	case TypeRerank:
		c = float64(u.Searches)*o.PerSearch + float64(u.TokensIn)*o.InputPrice/1e6
	}
	if c <= 0 {
		return 0
	}
	return int64(math.Ceil(c - 1e-9))
}

// videoRate is a video model's price a second at a resolution ("720p" or
// "1280x720"); the dearest when the request names none the model is priced at.
func videoRate(o dto.Offering, resolution string) float64 {
	if h := resolutionHeight(resolution); h > 0 {
		for r, v := range o.PerSecondBy {
			if resolutionHeight(r) == h {
				return v
			}
		}
	}
	return o.PerSecond
}

// isVercel is whether an offering is reached through Vercel AI Gateway, whose
// image, video, speech, transcription and reranking models are served by its
// own protocol rather than OpenAI-compatible endpoints.
func isVercel(o dto.Offering) bool {
	return o.Kind == "vercel" || strings.Contains(o.BaseURL, "ai-gateway.vercel.sh")
}

// vercelRoot is the gateway's origin, without the /v1 of its OpenAI-compatible base.
func vercelRoot(base string) string {
	return strings.TrimSuffix(strings.TrimRight(base, "/"), "/v1")
}

// vercelModelRequest is a call to one of Vercel's model endpoints
// (/v4/ai/{kind}-model, and /start or /status for video).
func vercelModelRequest(ctx context.Context, o dto.Offering, kind, suffix string, body any) (*http.Request, error) {
	raw, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, vercelRoot(o.BaseURL)+"/v4/ai/"+kind+"-model"+suffix, bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+o.APIKey)
	req.Header.Set("ai-gateway-protocol-version", "0.0.1")
	req.Header.Set("ai-"+kind+"-model-specification-version", "4")
	req.Header.Set("ai-model-id", o.Model)
	return req, nil
}

// errNotServed is a provider that cannot serve a kind of model.
var errNotServed = errors.New("this provider cannot serve this kind of model")

// upstream is the provider request for a call: the provider's OpenAI-compatible
// endpoint, or Vercel's own for the kinds it serves that way.
func (s *Service) upstream(ctx context.Context, c Call, a Attempt) (*http.Request, error) {
	o := a.Endpoint.offering
	pick := func(keys ...string) map[string]any {
		out := map[string]any{}
		for i := 0; i+1 < len(keys); i += 2 {
			if v, ok := c.Body[keys[i]]; ok && v != nil {
				out[keys[i+1]] = v
			}
		}
		return out
	}
	switch c.Type {
	case TypeLanguage, TypeEmbedding, TypeDecision:
		body := c.Body
		if c.Type == TypeLanguage && c.Stream {
			body = withUsage(body)
		}
		return upstreamRequest(ctx, a.Endpoint, typePath[c.Type], body)
	case TypeImage:
		if !isVercel(o) {
			return upstreamRequest(ctx, a.Endpoint, typePath[c.Type], c.Body)
		}
		body := pick("prompt", "prompt", "n", "n", "size", "size", "aspect_ratio", "aspectRatio", "seed", "seed", "provider_options", "providerOptions")
		if body["n"] == nil {
			body["n"] = 1
		}
		return vercelModelRequest(ctx, o, "image", "", body)
	case TypeSpeech:
		if !isVercel(o) {
			return nil, errNotServed
		}
		body := pick("input", "text", "voice", "voice", "response_format", "outputFormat", "speed", "speed",
			"instructions", "instructions", "language", "language", "provider_options", "providerOptions")
		return vercelModelRequest(ctx, o, "speech", "", body)
	case TypeTranscription:
		if !isVercel(o) {
			return nil, errNotServed
		}
		return vercelModelRequest(ctx, o, "transcription", "", pick("audio", "audio", "media_type", "mediaType", "provider_options", "providerOptions"))
	case TypeRerank:
		if !isVercel(o) {
			return nil, errNotServed
		}
		// Vercel's Cohere-compatible endpoint, which every reranking model it lists serves.
		body := pick("query", "query", "documents", "documents", "top_n", "top_n")
		body["model"] = o.Model
		raw, _ := json.Marshal(body)
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, vercelRoot(o.BaseURL)+"/v2/rerank", bytes.NewReader(raw))
		if err != nil {
			return nil, err
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+o.APIKey)
		return req, nil
	}
	return nil, errNotServed
}

// audioType is the media type of a speech format.
func audioType(format string) string {
	switch strings.ToLower(format) {
	case "wav":
		return "audio/wav"
	case "opus":
		return "audio/opus"
	case "aac":
		return "audio/aac"
	case "flac":
		return "audio/flac"
	case "pcm":
		return "audio/pcm"
	case "ogg":
		return "audio/ogg"
	}
	return "audio/mpeg"
}

// sniffAudio names audio by its first bytes, for a reply that does not say.
func sniffAudio(b []byte, asked string) string {
	switch {
	case bytes.HasPrefix(b, []byte("RIFF")):
		return "audio/wav"
	case bytes.HasPrefix(b, []byte("OggS")):
		return "audio/ogg"
	case bytes.HasPrefix(b, []byte("fLaC")):
		return "audio/flac"
	case bytes.HasPrefix(b, []byte("ID3")) || len(b) > 1 && b[0] == 0xFF && b[1]&0xE0 == 0xE0:
		return "audio/mpeg"
	}
	return audioType(asked)
}

// mediaUsage reads what a call of a non-token kind used, from its request and
// the provider's reply, and turns the reply into the API's. ok is false when
// the reply cannot be read.
func mediaUsage(c Call, reply map[string]any) (Usage, map[string]any, []byte, string, bool) {
	num := func(m map[string]any, key string) float64 {
		if v, ok := m[key].(float64); ok {
			return v
		}
		return 0
	}
	switch c.Type {
	case TypeImage:
		images, _ := reply["images"].([]any)
		if len(images) == 0 {
			return Usage{}, nil, nil, "", false
		}
		data := make([]map[string]any, 0, len(images))
		for _, img := range images {
			if b64, ok := img.(string); ok {
				data = append(data, map[string]any{"b64_json": b64})
			}
		}
		u := Usage{Images: int64(len(data))}
		if us, ok := reply["usage"].(map[string]any); ok {
			u.TokensIn, u.TokensOut = int64(num(us, "inputTokens")), int64(num(us, "outputTokens"))
		}
		out := map[string]any{"data": data, "usage": map[string]any{"images": u.Images, "input_tokens": u.TokensIn, "output_tokens": u.TokensOut}}
		if w, ok := reply["warnings"].([]any); ok && len(w) > 0 {
			out["warnings"] = w
		}
		return u, out, nil, "", true
	case TypeSpeech:
		b64, _ := reply["audio"].(string)
		audio, err := base64.StdEncoding.DecodeString(b64)
		if err != nil || len(audio) == 0 {
			return Usage{}, nil, nil, "", false
		}
		text, _ := c.Body["input"].(string)
		format, _ := c.Body["response_format"].(string)
		return Usage{Characters: int64(utf8.RuneCountInString(text))}, nil, audio, sniffAudio(audio, format), true
	case TypeTranscription:
		text, ok := reply["text"].(string)
		if !ok {
			return Usage{}, nil, nil, "", false
		}
		seconds := num(reply, "durationInSeconds")
		if seconds <= 0 {
			// No duration reported: about 16 KB a second of compressed audio.
			b64, _ := c.Body["audio"].(string)
			seconds = math.Max(1, float64(base64.StdEncoding.DecodedLen(len(b64)))/16000)
		}
		out := map[string]any{"text": text, "duration": seconds, "usage": map[string]any{"seconds": seconds}}
		if v, ok := reply["language"].(string); ok && v != "" {
			out["language"] = v
		}
		if v, ok := reply["segments"].([]any); ok && len(v) > 0 {
			out["segments"] = v
		}
		return Usage{Seconds: seconds}, out, nil, "", true
	case TypeRerank:
		results, ok := reply["results"].([]any)
		if !ok {
			return Usage{}, nil, nil, "", false
		}
		u := Usage{Searches: 1, TokensIn: rerankTokens(c.Body)}
		if meta, ok := reply["meta"].(map[string]any); ok {
			if billed, ok := meta["billed_units"].(map[string]any); ok && num(billed, "search_units") > 0 {
				u.Searches = int64(num(billed, "search_units"))
			}
		}
		out := map[string]any{"results": results, "usage": map[string]any{"searches": u.Searches, "input_tokens": u.TokensIn}}
		if id, ok := reply["id"].(string); ok {
			out["id"] = id
		}
		return u, out, nil, "", true
	}
	return Usage{}, nil, nil, "", false
}

// rerankTokens estimates a reranking request's tokens (4 characters a token):
// the query is read once for every document, as rerankers bill it.
func rerankTokens(body map[string]any) int64 {
	query, _ := body["query"].(string)
	docs, _ := body["documents"].([]any)
	n := 0
	for _, d := range docs {
		switch v := d.(type) {
		case string:
			n += len(v)
		default:
			b, _ := json.Marshal(v)
			n += len(b)
		}
		n += len(query)
	}
	return int64(n/4) + 1
}
