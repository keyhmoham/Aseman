package developer

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/developer/models"
	"github.com/tradera/tradera/plugins/actions/finance/models/wallet"
)

// minFunds is what an organization must hold to start a request (a tenth of a cent).
const minFunds = 1_000

// Endpoint paths of the model types.
var typePath = map[string]string{
	TypeLanguage:  "/chat/completions",
	TypeEmbedding: "/embeddings",
	TypeImage:     "/images/generations",
	// A decision model's evaluate endpoint sits next to the provider's OpenAI-compatible base (Vercel AI Gateway: .../v1/evaluate).
	TypeDecision: "/evaluate",
}

// publicPath is what each model type is called at on the API.
var publicPath = map[string]string{
	TypeLanguage:      "/v1/chat/completions",
	TypeEmbedding:     "/v1/embeddings",
	TypeImage:         "/v1/images/generations",
	TypeVideo:         "/v1/videos/generations",
	TypeSpeech:        "/v1/audio/speech",
	TypeTranscription: "/v1/audio/transcriptions",
	TypeDecision:      "/v1/decisions",
}

// Call is one model request, from the API or from the console's playground.
type Call struct {
	// Principal is the key the API request was made with; nil for the playground.
	Principal *Principal
	Org       identity.ID
	KeyID     string
	KeyName   string
	// Type is the kind of model the endpoint serves.
	Type string
	// Model and Fallbacks are as the request named them.
	Model     string
	Fallbacks []string
	Route     RouteOptions
	// Body is the request without the routing fields.
	Body   map[string]any
	Stream bool
}

// Result is what a call comes to: a reply, or a stream that is still to be
// written, or a refusal. Status and Body are always set unless Stream is.
type Result struct {
	Status int
	Header map[string]string
	Body   []byte
	// Stream, when set, writes the reply as it arrives; it bills and logs when done.
	Stream func(ctx context.Context, w io.Writer) error

	Model    string
	Provider string
	Cost     int64
	// TokensIn, TokensOut and LogID are set once the call is logged.
	TokensIn  int64
	TokensOut int64
	LogID     string
	// Skipped are the providers passed over before one answered.
	Skipped []attemptNote
}

func requestID() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return "req_" + hex.EncodeToString(b)
}

func errorBody(status int, typ, code, message, reqID string, extra map[string]any) *Result {
	e := map[string]any{"type": typ, "code": code, "message": message, "request_id": reqID}
	for k, v := range extra {
		e[k] = v
	}
	body, _ := json.Marshal(map[string]any{"error": e})
	return &Result{Status: status, Body: body, Header: map[string]string{"Content-Type": "application/json", "X-Tradera-Request-Id": reqID}}
}

func authFailure(err *AuthError, reqID string) *Result {
	return errorBody(err.Status, err.Type, err.Code, err.Message, reqID, nil)
}

// attemptNote records why a provider was passed over.
type attemptNote struct {
	Provider string `json:"provider"`
	Model    string `json:"model"`
	Status   int    `json:"status,omitempty"`
	Error    string `json:"error"`
}

// publicAttempts is what a developer is told of the attempts that failed: the
// model, the status and why, not which provider was tried.
func publicAttempts(notes []attemptNote) []map[string]any {
	out := make([]map[string]any, 0, len(notes))
	for _, n := range notes {
		a := map[string]any{"model": n.Model, "error": n.Error}
		if n.Status > 0 {
			a["status"] = n.Status
		}
		out = append(out, a)
	}
	return out
}

func retryable(status int) bool { return status >= 500 || status == 429 || status == 408 }

// allowed filters a plan down to what a key may use.
func allowed(p *Principal, plan Plan) (Plan, string) {
	if p == nil || (len(p.Limits.Models) == 0 && len(p.Limits.Providers) == 0) {
		return plan, ""
	}
	out := Plan{Notes: plan.Notes}
	denied := ""
	for _, a := range plan.Attempts {
		if len(p.Limits.Models) > 0 && !contains(p.Limits.Models, a.Model.ID) {
			denied = "This key may not call " + a.Model.ID + "."
			continue
		}
		if len(p.Limits.Providers) > 0 && !contains(p.Limits.Providers, a.Endpoint.Provider) {
			if denied == "" {
				denied = "This key may not use the provider " + a.Endpoint.Provider + "."
			}
			continue
		}
		out.Attempts = append(out.Attempts, a)
	}
	if len(out.Attempts) == 0 {
		out.Err = denied
	}
	return out, denied
}

// Execute runs a model request: it routes it, calls the providers in order until
// one answers, bills the organization for what it used and logs the call.
func (s *Service) Execute(ctx context.Context, c Call) *Result {
	started := s.now()
	reqID := requestID()
	logCall := func(res *Result, model, provider string, in, out, cost int64, response any, errText string) {
		res.LogID, res.TokensIn, res.TokensOut, res.Cost = s.writeLog(context.WithoutCancel(ctx), models.Log{OrgID: c.Org.String(), KeyID: c.KeyID, KeyName: c.KeyName, Service: "models", Method: "POST",
			Path: publicPath[c.Type], Status: int64(res.Status), LatencyMs: s.now().Sub(started).Milliseconds(), Model: model, Provider: provider,
			RequestedModel: c.Model, TokensIn: in, TokensOut: out, Cost: cost, Request: clip(jsonString(c.requestView()), 4000), Response: clip(jsonString(response), 4000), Error: errText}), in, out, cost
		if c.Principal != nil {
			s.recordUse(context.WithoutCancel(ctx), c.Principal, cost)
		}
	}
	refuse := func(status int, typ, code, message string, extra map[string]any) *Result {
		r := errorBody(status, typ, code, message, reqID, extra)
		logCall(r, c.Model, "", 0, 0, 0, nil, message)
		return r
	}

	if c.Principal != nil {
		if err := c.Principal.Need("chat", LevelWrite); err != nil {
			return refuse(403, "permission_error", "permission_denied", err.Error(), nil)
		}
		if err := s.SpendCheck(ctx, c.Principal); err != nil {
			if ae, ok := err.(*AuthError); ok {
				return refuse(ae.Status, ae.Type, ae.Code, ae.Message, nil)
			}
			return refuse(500, "api_error", "internal_error", "Could not check the spending limits.", nil)
		}
	}
	catalog, err := s.Catalog(ctx)
	if err != nil {
		return refuse(503, "api_error", "catalog_unavailable", "The model catalog is unavailable right now.", nil)
	}
	plan := PlanRoute(catalog, c.Model, c.Route, c.Fallbacks)
	plan, denied := allowed(c.Principal, plan)
	// Only models of the endpoint's own type can answer it.
	var attempts []Attempt
	for _, a := range plan.Attempts {
		if a.Model.Type == c.Type {
			attempts = append(attempts, a)
		}
	}
	if len(attempts) == 0 {
		if first := FindModel(catalog, firstRef(c.Model)); first != nil && first.Type != c.Type && denied == "" {
			return refuse(400, "invalid_request_error", "wrong_model_type", fmt.Sprintf("%s is a %s model: use POST %s.", first.ID, first.Type, publicPath[first.Type]), nil)
		}
		if denied != "" {
			return refuse(403, "permission_error", "model_not_allowed", denied, nil)
		}
		if FindModel(catalog, firstRef(c.Model)) == nil {
			return refuse(404, "not_found_error", "model_not_found", "No model named "+firstRef(c.Model)+". List the models with GET /v1/models.", nil)
		}
		return refuse(404, "not_found_error", "no_provider", "No provider can serve this request with those provider options.", map[string]any{"notes": plan.Notes})
	}
	if err := s.Fin.EnsureFunds(ctx, c.Org, minFunds); err != nil {
		return refuse(402, "billing_error", "insufficient_funds", "This organization's balance is too low. Add funds under Billing in the console.", nil)
	}

	var skipped []attemptNote
	for _, a := range attempts {
		up, err := s.upstream(ctx, c, a)
		if err != nil {
			skipped = append(skipped, attemptNote{a.Endpoint.Provider, a.Model.ID, 0, err.Error()})
			continue
		}
		if c.Stream {
			up.Header.Set("Accept", "text/event-stream")
		}
		resp, err := s.HTTP.Do(up)
		if err != nil && ctx.Err() != nil {
			return s.abandoned(ctx, c, a, reqID, skipped, logCall)
		}
		if err != nil {
			skipped = append(skipped, attemptNote{a.Endpoint.Provider, a.Model.ID, 0, "could not reach the provider"})
			s.L.Warn("developer: provider unreachable", "provider", a.Endpoint.Provider, "error", err)
			continue
		}
		if resp.StatusCode >= 300 {
			data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
			_ = resp.Body.Close()
			if retryable(resp.StatusCode) {
				skipped = append(skipped, attemptNote{a.Endpoint.Provider, a.Model.ID, resp.StatusCode, upstreamMessage(data)})
				continue
			}
			// The request itself was refused: another provider would refuse it too.
			r := errorBody(resp.StatusCode, "invalid_request_error", "upstream_rejected", upstreamMessage(data), reqID, nil)
			logCall(r, a.Model.ID, a.Endpoint.Provider, 0, 0, 0, nil, upstreamMessage(data))
			return r
		}
		if c.Stream {
			return s.streamResult(ctx, c, a, resp, reqID, started, skipped, logCall)
		}
		data, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
		_ = resp.Body.Close()
		if err != nil && ctx.Err() != nil {
			return s.abandoned(ctx, c, a, reqID, skipped, logCall)
		}
		if err != nil {
			skipped = append(skipped, attemptNote{a.Endpoint.Provider, a.Model.ID, 0, "the provider's reply was cut short"})
			continue
		}
		return s.finish(ctx, c, a, data, reqID, skipped, logCall)
	}
	r := errorBody(502, "api_error", "model_unavailable", "The model could not answer. Try again, or add fallback models.", reqID, map[string]any{"attempts": publicAttempts(skipped)})
	r.Skipped = skipped
	logCall(r, c.Model, "", 0, 0, 0, nil, "all providers failed")
	return r
}

func firstRef(model string) string {
	id, _ := ParseModelRef(model)
	return id
}

func withUsage(body map[string]any) map[string]any {
	out := make(map[string]any, len(body)+1)
	for k, v := range body {
		out[k] = v
	}
	opts, _ := out["stream_options"].(map[string]any)
	next := map[string]any{"include_usage": true}
	for k, v := range opts {
		next[k] = v
	}
	out["stream_options"] = next
	return out
}

func upstreamMessage(data []byte) string {
	var v struct {
		Error any    `json:"error"`
		Msg   string `json:"message"`
	}
	if json.Unmarshal(data, &v) == nil {
		switch e := v.Error.(type) {
		case string:
			return clip(e, 400)
		case map[string]any:
			if m, ok := e["message"].(string); ok {
				return clip(m, 400)
			}
		}
		if v.Msg != "" {
			return clip(v.Msg, 400)
		}
	}
	return clip(strings.TrimSpace(string(data)), 400)
}

func clip(text string, max int) string {
	if len(text) <= max {
		return text
	}
	return text[:max] + "…"
}

func jsonString(v any) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	b, _ := json.Marshal(v)
	return string(b)
}

// requestView is the request as the log keeps it.
func (c Call) requestView() map[string]any {
	view := map[string]any{"model": c.Model}
	for k, v := range c.Body {
		view[k] = v
	}
	if len(c.Fallbacks) > 0 {
		view["models"] = c.Fallbacks
	}
	if r, _ := json.Marshal(c.Route); string(r) != "{}" {
		view["provider"] = c.Route
	}
	return view
}

// usageOf reads token counts from a provider reply.
func usageOf(reply map[string]any) (in, out int64) {
	u, _ := reply["usage"].(map[string]any)
	num := func(key string) int64 {
		switch n := u[key].(type) {
		case float64:
			return int64(n)
		}
		return 0
	}
	in, out = num("prompt_tokens"), num("completion_tokens")
	if in == 0 && out == 0 { // a decision model reports its usage camel-cased
		in, out = num("inputTokens"), num("outputTokens")
	}
	if in == 0 && out == 0 {
		in = num("total_tokens")
	}
	return in, out
}

// bill charges the organization for a call, paying the provider key's owner.
func (s *Service) bill(ctx context.Context, c Call, a Attempt, cost int64) {
	if cost <= 0 {
		return
	}
	desc := "developer API: " + a.Model.ID + " via " + a.Endpoint.Provider
	lines := []wallet.ChargeLine{{Amount: cost, Payees: []identity.ID{a.Endpoint.offering.Owner}, Type: wallet.EntryPayLLM, Category: wallet.CategoryLLM, Desc: desc}}
	if err := s.Fin.ChargeLines(ctx, c.Org, desc, lines); err != nil {
		// The reply is already given; the shortfall is a loss to note, not to hide.
		s.L.Warn("developer: could not bill a served request", "org", c.Org.String(), "cost", cost, "error", err)
	}
}

// finish turns a provider's complete reply into the API's: the canonical model,
// the provider that answered, and what it cost in dollars.
func (s *Service) finish(ctx context.Context, c Call, a Attempt, data []byte, reqID string, skipped []attemptNote, logCall func(*Result, string, string, int64, int64, int64, any, string)) *Result {
	var reply map[string]any
	if err := json.Unmarshal(data, &reply); err != nil {
		r := errorBody(502, "api_error", "bad_provider_reply", "The provider's reply could not be read.", reqID, nil)
		logCall(r, a.Model.ID, a.Endpoint.Provider, 0, 0, 0, nil, "unreadable provider reply")
		return r
	}
	if c.Type == TypeSpeech || c.Type == TypeTranscription || c.Type == TypeRerank || c.Type == TypeImage && isVercel(a.Endpoint.offering) {
		return s.finishMedia(ctx, c, a, reply, reqID, skipped, logCall)
	}
	in, out := usageOf(reply)
	var images int64
	if list, ok := reply["data"].([]any); ok && c.Type == TypeImage {
		images = int64(len(list))
	}
	cost := costOf(c.Type, a.Endpoint, Usage{TokensIn: in, TokensOut: out, Images: images})
	s.bill(ctx, c, a, cost)
	// The reply names the model that answered; who served it stays the node's business.
	reply["model"] = a.Model.ID
	delete(reply, "provider")
	u, _ := reply["usage"].(map[string]any)
	if u == nil {
		u = map[string]any{}
	}
	u["cost"] = usd(float64(cost))
	reply["usage"] = u
	if len(skipped) > 0 {
		reply["fallbacks_used"] = publicAttempts(skipped)
	}
	body, _ := json.Marshal(reply)
	res := &Result{Status: 200, Body: body, Model: a.Model.ID, Provider: a.Endpoint.Provider, Cost: cost, Header: map[string]string{
		"Content-Type": "application/json", "X-Tradera-Model": a.Model.ID, "X-Tradera-Request-Id": reqID}}
	res.Skipped = skipped
	logCall(res, a.Model.ID, a.Endpoint.Provider, in, out, cost, reply, "")
	return res
}

// streamResult answers a streamed chat request: the provider's events are
// passed on as they come, tagged with the canonical model and provider, and the
// call is billed and logged when the stream ends.
func (s *Service) streamResult(ctx context.Context, c Call, a Attempt, resp *http.Response, reqID string, started time.Time, skipped []attemptNote, logCall func(*Result, string, string, int64, int64, int64, any, string)) *Result {
	res := &Result{Status: 200, Model: a.Model.ID, Provider: a.Endpoint.Provider, Header: map[string]string{
		"Content-Type": "text/event-stream", "Cache-Control": "no-cache", "X-Tradera-Model": a.Model.ID, "X-Tradera-Request-Id": reqID}}
	res.Stream = func(ctx context.Context, w io.Writer) error {
		defer resp.Body.Close()
		reader := bufio.NewReaderSize(resp.Body, 64<<10)
		var in, out int64
		var text strings.Builder
		var streamErr error
		for {
			line, err := reader.ReadBytes('\n')
			if len(line) > 0 {
				trimmed := bytes.TrimSpace(line)
				switch {
				case len(trimmed) == 0:
				case bytes.HasPrefix(trimmed, []byte("data:")):
					payload := bytes.TrimSpace(bytes.TrimPrefix(trimmed, []byte("data:")))
					if string(payload) == "[DONE]" {
						_, _ = io.WriteString(w, "data: [DONE]\n\n")
						break
					}
					var chunk map[string]any
					if json.Unmarshal(payload, &chunk) != nil {
						_, _ = fmt.Fprintf(w, "data: %s\n\n", payload)
						break
					}
					chunk["model"] = a.Model.ID
					delete(chunk, "provider")
					if choices, ok := chunk["choices"].([]any); ok {
						for _, ch := range choices {
							if m, ok := ch.(map[string]any); ok {
								if d, ok := m["delta"].(map[string]any); ok {
									if t, ok := d["content"].(string); ok && text.Len() < 4000 {
										text.WriteString(t)
									}
								}
							}
						}
					}
					if u, ok := chunk["usage"].(map[string]any); ok && u != nil {
						in, out = usageOf(chunk)
						u["cost"] = usd(float64(costOf(c.Type, a.Endpoint, Usage{TokensIn: in, TokensOut: out})))
					}
					b, _ := json.Marshal(chunk)
					_, _ = fmt.Fprintf(w, "data: %s\n\n", b)
				default:
					// A comment or keep-alive: pass it on as it is.
					_, _ = fmt.Fprintf(w, "%s\n\n", trimmed)
				}
			}
			if err != nil {
				if err != io.EOF {
					streamErr = err
				}
				break
			}
		}
		status, errText := 200, ""
		if streamErr != nil {
			status, errText = 499, "the stream ended early: "+streamErr.Error()
		}
		if in == 0 && out == 0 && text.Len() > 0 { // no usage arrived: bill what was written
			in, out = estimateTokens(c.Body), int64(text.Len()/4)+1
		}
		cost := costOf(c.Type, a.Endpoint, Usage{TokensIn: in, TokensOut: out})
		ctx = context.WithoutCancel(ctx)
		s.bill(ctx, c, a, cost)
		done := &Result{Status: status}
		logCall(done, a.Model.ID, a.Endpoint.Provider, in, out, cost, map[string]any{"stream": true, "content": text.String(), "fallbacks_used": publicAttempts(skipped)}, errText)
		return nil
	}
	return res
}

// abandoned answers a request whose caller went away before the provider's
// reply: the provider was sent the request and bills its input, so the
// organization pays for the estimated input (nothing for an output it never
// received), and the request is logged as 499.
func (s *Service) abandoned(ctx context.Context, c Call, a Attempt, reqID string, skipped []attemptNote, logCall func(*Result, string, string, int64, int64, int64, any, string)) *Result {
	var in int64
	if c.Type == TypeLanguage || c.Type == TypeEmbedding || c.Type == TypeDecision {
		in = estimateTokens(c.Body)
	}
	cost := costOf(c.Type, a.Endpoint, Usage{TokensIn: in})
	s.bill(context.WithoutCancel(ctx), c, a, cost)
	r := errorBody(499, "api_error", "client_closed", "The request was cancelled before the provider answered.", reqID, nil)
	logCall(r, a.Model.ID, a.Endpoint.Provider, in, 0, cost, map[string]any{"fallbacks_used": publicAttempts(skipped)}, "the caller went away before the reply (input estimated)")
	return r
}

// estimateTokens is a rough input size (4 characters a token) for a call that
// ended before the provider reported its usage.
func estimateTokens(body map[string]any) int64 {
	b, _ := json.Marshal(body["messages"])
	return int64(len(b) / 4)
}

// finishMedia turns the reply of an image, speech, transcription or reranking
// model into the API's, bills what it used and logs it. Speech is answered
// with the audio itself, as OpenAI's API does; the rest with JSON.
func (s *Service) finishMedia(ctx context.Context, c Call, a Attempt, reply map[string]any, reqID string, skipped []attemptNote, logCall func(*Result, string, string, int64, int64, int64, any, string)) *Result {
	u, out, audio, audioType, ok := mediaUsage(c, reply)
	if !ok {
		r := errorBody(502, "api_error", "bad_provider_reply", "The provider's reply could not be read.", reqID, nil)
		logCall(r, a.Model.ID, a.Endpoint.Provider, 0, 0, 0, nil, "unreadable provider reply")
		return r
	}
	cost := costOf(c.Type, a.Endpoint, u)
	s.bill(ctx, c, a, cost)
	header := map[string]string{"X-Tradera-Model": a.Model.ID,
		"X-Tradera-Request-Id": reqID, "X-Tradera-Cost": strconv.FormatFloat(usd(float64(cost)), 'f', -1, 64)}
	res := &Result{Status: 200, Header: header, Model: a.Model.ID, Provider: a.Endpoint.Provider, Cost: cost, Skipped: skipped}
	var logged any
	if audio != nil {
		header["Content-Type"] = audioType
		res.Body = audio
		logged = map[string]any{"audio_bytes": len(audio), "content_type": audioType, "characters": u.Characters}
	} else {
		header["Content-Type"] = "application/json"
		out["model"] = a.Model.ID
		if c.Type == TypeImage {
			out["created"] = s.now().Unix()
		}
		usage, _ := out["usage"].(map[string]any)
		usage["cost"] = usd(float64(cost))
		if len(skipped) > 0 {
			out["fallbacks_used"] = publicAttempts(skipped)
		}
		res.Body, _ = json.Marshal(out)
		logged = out
		if c.Type == TypeImage { // the log keeps what was made, not the pictures
			logged = map[string]any{"images": u.Images, "usage": usage, "model": a.Model.ID}
		}
	}
	logCall(res, a.Model.ID, a.Endpoint.Provider, u.TokensIn, u.TokensOut, cost, logged, "")
	return res
}
