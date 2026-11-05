package developer

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// The developer API's routes live under this prefix in the node's router; the
// network adapter maps the developer host's /v1/... onto it (see the http
// adapter's `developer_host`).
const apiPrefix = "/dev/v1"

// maxDecisionQuestions bounds one decision request.
const maxDecisionQuestions = 300

// maxAudioBytes bounds the audio of one transcription, as OpenAI's API does.
const maxAudioBytes = 25 << 20

// transcriptionForm reads an OpenAI-style transcription upload: the audio
// `file` and the `model`, with the other fields as they are.
func transcriptionForm(req *network.Request) (map[string]any, error) {
	mediaType, params, err := mime.ParseMediaType(header(req, "Content-Type"))
	if err != nil || !strings.HasPrefix(mediaType, "multipart/") || params["boundary"] == "" {
		return nil, errors.New("The form could not be read.")
	}
	body := map[string]any{}
	reader := multipart.NewReader(bytes.NewReader(req.Body), params["boundary"])
	for {
		part, err := reader.NextPart()
		if err != nil {
			break
		}
		data, err := io.ReadAll(io.LimitReader(part, maxAudioBytes+1))
		if err != nil {
			return nil, errors.New("The upload could not be read.")
		}
		if part.FormName() != "file" {
			body[part.FormName()] = strings.TrimSpace(string(data))
			continue
		}
		if len(data) > maxAudioBytes {
			return nil, errors.New("The audio is larger than 25 MB.")
		}
		mt := part.Header.Get("Content-Type")
		if mt == "" || mt == "application/octet-stream" {
			mt = mime.TypeByExtension(strings.ToLower(filepath.Ext(part.FileName())))
		}
		if mt == "" {
			mt = "audio/mpeg"
		}
		body["audio"], body["media_type"] = base64.StdEncoding.EncodeToString(data), mt
	}
	if body["audio"] == nil {
		return nil, errors.New("The form needs the audio in a field called file.")
	}
	return body, nil
}

type route struct {
	method  network.Method
	pattern string
	handler network.Handler
}

func (s *Service) routes() []route {
	out := append(s.modelRoutes(), s.apiComputers()...)
	out = append(out, s.apiPlatform()...)
	return append(out, s.apiWorkflows()...)
}

func (s *Service) modelRoutes() []route {
	get := func(p string, h network.Handler) route { return route{network.MethodGet, apiPrefix + p, h} }
	post := func(p string, h network.Handler) route { return route{network.MethodPost, apiPrefix + p, h} }
	return []route{
		get("/models", s.apiModels),
		get("/models/{creator}/{name}", s.apiModel),
		post("/chat/completions", s.apiRun(TypeLanguage)),
		post("/embeddings", s.apiRun(TypeEmbedding)),
		post("/images/generations", s.apiRun(TypeImage)),
		post("/videos/generations", s.apiVideoStart),
		get("/videos/{id}", s.apiVideoStatus),
		post("/audio/speech", s.apiRun(TypeSpeech)),
		post("/audio/transcriptions", s.apiRun(TypeTranscription)),
		post("/rerank", s.apiRun(TypeRerank)),
		post("/decisions", s.apiRun(TypeDecision)),
		post("/evaluate", s.apiRun(TypeDecision)), // the name the AI gateways and TypeSafe's own clients use
		get("/balance", s.apiBalance),
		get("/organization", s.apiOrganization),
		get("/usage", s.apiUsage),
	}
}

// Register binds the API's routes to a network adapter.
func (s *Service) Register(net network.Network) error {
	for _, r := range s.routes() {
		if err := net.Handle(r.method, r.pattern, r.handler); err != nil {
			return err
		}
	}
	return nil
}

// Unregister removes them.
func (s *Service) Unregister(net network.Network) error {
	for _, r := range s.routes() {
		_ = net.Unhandle(r.method, r.pattern)
	}
	return nil
}

func jsonResponse(status int, v any, header map[string]string) *network.Response {
	b, _ := json.Marshal(v)
	h := map[string]string{"Content-Type": "application/json"}
	for k, val := range header {
		h[k] = val
	}
	return &network.Response{Status: status, Header: h, Body: b}
}

func fromResult(r *Result) *network.Response {
	if r.Stream != nil {
		return &network.Response{Status: r.Status, Header: r.Header, Stream: r.Stream}
	}
	return &network.Response{Status: r.Status, Header: r.Header, Body: r.Body}
}

func bearer(req *network.Request) string {
	for k, v := range req.Header {
		if strings.EqualFold(k, "Authorization") {
			if strings.HasPrefix(v, "Bearer ") {
				return strings.TrimSpace(strings.TrimPrefix(v, "Bearer "))
			}
		}
	}
	return ""
}

// authenticated runs an API handler for a request with a usable key: it
// answers the ones without, and the ones over their rate limit.
func (s *Service) authenticated(req *network.Request, run func(p *Principal, rate map[string]string) *network.Response) *network.Response {
	reqID := requestID()
	p, err := s.Authenticate(context.Background(), bearer(req))
	if err != nil {
		var ae *AuthError
		if errors.As(err, &ae) {
			return fromResult(authFailure(ae, reqID))
		}
		s.L.Warn("developer: authenticating a key", "error", err)
		return fromResult(errorBody(500, "api_error", "internal_error", "Something went wrong on our side.", reqID, nil))
	}
	limit, remaining, retry, ok := s.Allow(p)
	rate := map[string]string{"X-RateLimit-Limit": strconv.FormatInt(limit, 10), "X-RateLimit-Remaining": strconv.FormatInt(remaining, 10), "X-Aseman-Request-Id": reqID}
	if !ok {
		r := errorBody(429, "rate_limit_error", "rate_limited", "Rate limit reached for this key. Retry after "+strconv.Itoa(retry)+" seconds.", reqID, nil)
		r.Header["Retry-After"] = strconv.Itoa(retry)
		for k, v := range rate {
			r.Header[k] = v
		}
		return fromResult(r)
	}
	resp := run(p, rate)
	if resp.Header == nil {
		resp.Header = map[string]string{}
	}
	for k, v := range rate {
		if _, set := resp.Header[k]; !set {
			resp.Header[k] = v
		}
	}
	return resp
}

func denied(err error, reqID string) *network.Response {
	var ae *AuthError
	if errors.As(err, &ae) {
		return fromResult(authFailure(ae, reqID))
	}
	return fromResult(errorBody(500, "api_error", "internal_error", "Something went wrong on our side.", reqID, nil))
}

func (s *Service) unavailable(what string) network.Handler {
	return func(ctx context.Context, req *network.Request) (*network.Response, error) {
		return s.authenticated(req, func(p *Principal, _ map[string]string) *network.Response {
			return fromResult(errorBody(501, "api_error", "not_available", "This node serves no "+what+" models yet.", requestID(), nil))
		}), nil
	}
}

// providerBody is a model's providers as the API lists them, prices in dollars.
func providerBody(e Endpoint) map[string]any {
	pricing := make([]map[string]any, 0, len(e.Prices))
	for _, p := range e.Prices {
		pricing = append(pricing, map[string]any{"label": strings.ToLower(p.Label), "usd": usd(p.Units), "per": p.Per})
	}
	out := map[string]any{"id": e.Provider, "name": e.ProviderName, "model": e.UpstreamID, "default": e.IsDefault, "pricing": pricing}
	if e.Stats != nil {
		out["latency_ms"], out["tokens_per_second"] = e.Stats.LatencyMs, e.Stats.TokensPerSecond
	}
	return out
}

// modelBody is a model as the API lists it, priced at the provider that
// answers when a request names none; nil when the key may use none of them.
func modelBody(m CatalogModel, p *Principal) map[string]any {
	var serving *Endpoint
	for i := range m.Endpoints {
		e := &m.Endpoints[i]
		if p != nil && len(p.Limits.Providers) > 0 && !contains(p.Limits.Providers, e.Provider) {
			continue
		}
		if serving == nil || e.IsDefault {
			serving = e
		}
	}
	if serving == nil {
		return nil
	}
	out := map[string]any{"id": m.ID, "object": "model", "name": m.Name, "creator": m.Creator, "type": m.Type,
		"modalities": m.Modalities, "capabilities": m.Capabilities, "pricing": providerBody(*serving)["pricing"]}
	if m.ContextWindow > 0 {
		out["context_window"] = m.ContextWindow
	}
	return out
}

// visible is whether a key may see a model at all.
func visible(p *Principal, m CatalogModel) bool {
	return len(p.Limits.Models) == 0 || contains(p.Limits.Models, m.ID)
}

func (s *Service) apiModels(ctx context.Context, req *network.Request) (*network.Response, error) {
	return s.authenticated(req, func(p *Principal, _ map[string]string) *network.Response {
		if err := p.Need("models", LevelRead); err != nil {
			return denied(err, requestID())
		}
		catalog, err := s.Catalog(ctx)
		if err != nil {
			return fromResult(errorBody(503, "api_error", "catalog_unavailable", "The model catalog is unavailable right now.", requestID(), nil))
		}
		typ := req.Query.Get("type")
		data := []map[string]any{}
		for _, m := range catalog {
			if !visible(p, m) || typ != "" && m.Type != typ {
				continue
			}
			if body := modelBody(m, p); body != nil {
				data = append(data, body)
			}
		}
		return jsonResponse(200, map[string]any{"object": "list", "data": data}, nil)
	}), nil
}

func routeParams(req *network.Request) map[string]string {
	params := map[string]string{}
	if raw := req.Header["x-route-params"]; raw != "" {
		_ = json.Unmarshal([]byte(raw), &params)
	}
	return params
}

func (s *Service) findForKey(ctx context.Context, req *network.Request, p *Principal) (*CatalogModel, *network.Response) {
	params := routeParams(req)
	catalog, err := s.Catalog(ctx)
	if err != nil {
		return nil, fromResult(errorBody(503, "api_error", "catalog_unavailable", "The model catalog is unavailable right now.", requestID(), nil))
	}
	m := FindModel(catalog, params["creator"]+"/"+params["name"])
	if m == nil || !visible(p, *m) {
		return nil, fromResult(errorBody(404, "not_found_error", "model_not_found", "No model named "+params["creator"]+"/"+params["name"]+".", requestID(), nil))
	}
	return m, nil
}

func (s *Service) apiModel(ctx context.Context, req *network.Request) (*network.Response, error) {
	return s.authenticated(req, func(p *Principal, _ map[string]string) *network.Response {
		if err := p.Need("models", LevelRead); err != nil {
			return denied(err, requestID())
		}
		m, bad := s.findForKey(ctx, req, p)
		if bad != nil {
			return bad
		}
		body := modelBody(*m, p)
		if body == nil {
			return fromResult(errorBody(404, "not_found_error", "model_not_found", "No model named "+m.ID+".", requestID(), nil))
		}
		return jsonResponse(200, body, nil)
	}), nil
}

// apiRun serves a model endpoint.
func (s *Service) apiRun(typ string) network.Handler {
	return func(ctx context.Context, req *network.Request) (*network.Response, error) {
		return s.authenticated(req, func(p *Principal, _ map[string]string) *network.Response {
			reqID := requestID()
			var body map[string]any
			if typ == TypeTranscription && strings.HasPrefix(strings.ToLower(header(req, "Content-Type")), "multipart/") {
				form, err := transcriptionForm(req)
				if err != nil {
					return fromResult(errorBody(400, "invalid_request_error", "invalid_request", err.Error(), reqID, nil))
				}
				body = form
			} else if err := json.Unmarshal(req.Body, &body); err != nil || body == nil {
				return fromResult(errorBody(400, "invalid_request_error", "invalid_json", "The request body must be a JSON object.", reqID, nil))
			}
			c, bad := parseCall(typ, body)
			if bad != "" {
				return fromResult(errorBody(400, "invalid_request_error", "invalid_request", bad, reqID, nil))
			}
			c.Principal, c.Org, c.KeyID, c.KeyName = p, p.Org, p.Key.ID.String(), p.Key.Name
			return fromResult(s.Execute(ctx, c))
		}), nil
	}
}

// parseCall reads a model request: the routing fields are lifted out and the
// rest is the provider's own request.
func parseCall(typ string, body map[string]any) (Call, string) {
	c := Call{Type: typ}
	model, _ := body["model"].(string)
	if strings.TrimSpace(model) == "" {
		return c, "`model` is required, for example google/gemini-3.8-flash."
	}
	c.Model = strings.TrimSpace(model)
	if list, ok := body["models"].([]any); ok {
		for _, m := range list {
			if name, ok := m.(string); ok && strings.TrimSpace(name) != "" {
				c.Fallbacks = append(c.Fallbacks, strings.TrimSpace(name))
			}
		}
	}
	if raw, ok := body["provider"]; ok {
		route, bad := parseProvider(raw)
		if bad != "" {
			return c, bad
		}
		c.Route = route
	}
	switch typ {
	case TypeLanguage:
		if _, ok := body["messages"].([]any); !ok {
			return c, "`messages` is required: a list of {role, content}."
		}
	case TypeEmbedding:
		if body["input"] == nil {
			return c, "`input` is required: a text or a list of texts."
		}
	case TypeImage:
		if p, _ := body["prompt"].(string); strings.TrimSpace(p) == "" {
			return c, "`prompt` is required."
		}
	case TypeSpeech:
		if t, _ := body["input"].(string); strings.TrimSpace(t) == "" {
			return c, "`input` is required: the text to speak."
		}
	case TypeTranscription:
		audio, _ := body["audio"].(string)
		if audio == "" {
			return c, "Send the audio as a `file` in multipart form data, or as base64 `audio` with its `media_type` in JSON."
		}
		if base64.StdEncoding.DecodedLen(len(audio)) > maxAudioBytes {
			return c, "The audio is larger than 25 MB."
		}
		if mt, _ := body["media_type"].(string); mt == "" {
			body["media_type"] = "audio/mpeg"
		}
	case TypeRerank:
		if q, _ := body["query"].(string); strings.TrimSpace(q) == "" {
			return c, "`query` is required."
		}
		docs, _ := body["documents"].([]any)
		if len(docs) == 0 || len(docs) > 1000 {
			return c, "`documents` is required: a list of 1 to 1000 texts."
		}
	case TypeDecision:
		if body["state"] == nil || body["state"] == "" {
			return c, "`state` is required: the text or JSON the questions are about."
		}
		questions, _ := body["questions"].(map[string]any)
		if len(questions) == 0 {
			return c, "`questions` is required: a map of question names to {type, instructions}."
		}
		if len(questions) > maxDecisionQuestions {
			return c, "`questions` may hold at most " + strconv.Itoa(maxDecisionQuestions) + " questions."
		}
	}
	c.Stream, _ = body["stream"].(bool)
	if c.Stream && typ != TypeLanguage {
		c.Stream = false
	}
	c.Body = map[string]any{}
	for k, v := range body {
		switch k {
		case "model", "models", "provider":
		default:
			c.Body[k] = v
		}
	}
	return c, ""
}

func stringList(v any) []string {
	list, _ := v.([]any)
	var out []string
	for _, x := range list {
		if s, ok := x.(string); ok && s != "" {
			out = append(out, s)
		}
	}
	return out
}

// parseProvider reads the request's `provider` object. max_price is in dollars
// per 1M tokens, as the docs say; the engine counts ledger units.
func parseProvider(raw any) (RouteOptions, string) {
	m, ok := raw.(map[string]any)
	if !ok {
		return RouteOptions{}, "`provider` must be an object."
	}
	r := RouteOptions{Order: stringList(m["order"]), Only: stringList(m["only"]), Ignore: stringList(m["ignore"])}
	if v, ok := m["allow_fallbacks"].(bool); ok {
		r.AllowFallbacks = &v
	}
	if sort, ok := m["sort"].(string); ok && sort != "" {
		switch sort {
		case "price", "latency", "throughput":
			r.Sort = sort
		default:
			return r, "`provider.sort` must be price, latency or throughput."
		}
	}
	if mp, ok := m["max_price"].(map[string]any); ok {
		r.MaxPrice = &MaxPrice{}
		if v, ok := mp["input"].(float64); ok {
			u := units(v)
			r.MaxPrice.Input = &u
		}
		if v, ok := mp["output"].(float64); ok {
			u := units(v)
			r.MaxPrice.Output = &u
		}
	}
	return r, ""
}

func (s *Service) apiBalance(ctx context.Context, req *network.Request) (*network.Response, error) {
	return s.authenticated(req, func(p *Principal, _ map[string]string) *network.Response {
		if err := p.Need("usage", LevelRead); err != nil {
			return denied(err, requestID())
		}
		w, err := s.Fin.GetWallet(ctx, p.Org)
		if err != nil {
			return fromResult(errorBody(500, "api_error", "internal_error", "The balance could not be read.", requestID(), nil))
		}
		return jsonResponse(200, map[string]any{"available": usd(float64(w.Available())), "held": usd(float64(w.Locked)), "currency": "USD"}, nil)
	}), nil
}

func (s *Service) apiOrganization(ctx context.Context, req *network.Request) (*network.Response, error) {
	return s.authenticated(req, func(p *Principal, _ map[string]string) *network.Response {
		if err := p.Need("usage", LevelRead); err != nil {
			return denied(err, requestID())
		}
		w, err := s.Fin.GetWallet(ctx, p.Org)
		if err != nil {
			return fromResult(errorBody(500, "api_error", "internal_error", "The balance could not be read.", requestID(), nil))
		}
		return jsonResponse(200, map[string]any{"id": p.Org.String(), "name": p.OrgName,
			"balance": map[string]any{"available": usd(float64(w.Available())), "held": usd(float64(w.Locked)), "currency": "USD"}}, nil)
	}), nil
}

func (s *Service) apiUsage(ctx context.Context, req *network.Request) (*network.Response, error) {
	return s.authenticated(req, func(p *Principal, _ map[string]string) *network.Response {
		if err := p.Need("usage", LevelRead); err != nil {
			return denied(err, requestID())
		}
		days, _ := strconv.Atoi(req.Query.Get("days"))
		report, err := s.Usage(ctx, p.Org, days, 0)
		if err != nil {
			return fromResult(errorBody(500, "api_error", "internal_error", "Usage could not be read.", requestID(), nil))
		}
		var data []map[string]any
		switch req.Query.Get("group_by") {
		case "model":
			for _, r := range report.ByModel {
				data = append(data, map[string]any{"model": r.Name, "spend": usd(float64(r.Spend)), "requests": r.Requests, "tokens": r.Tokens})
			}
		case "key":
			for _, r := range report.ByKey {
				data = append(data, map[string]any{"key": r.Name, "spend": usd(float64(r.Spend)), "requests": r.Requests, "tokens": r.Tokens})
			}
		case "service":
			for _, r := range report.ByService {
				data = append(data, map[string]any{"service": r.Name, "spend": usd(float64(r.Spend)), "requests": r.Requests, "tokens": r.Tokens})
			}
		default:
			for _, d := range report.Days {
				data = append(data, map[string]any{"day": d.Day, "spend": usd(float64(d.Spend)), "requests": d.Requests, "input_tokens": d.TokensIn, "output_tokens": d.TokensOut})
			}
		}
		t := report.Total
		return jsonResponse(http.StatusOK, map[string]any{"total": map[string]any{"spend": usd(float64(t.Spend)), "requests": t.Requests, "input_tokens": t.TokensIn, "output_tokens": t.TokensOut, "errors": t.Errors, "currency": "USD"}, "data": data}, nil)
	}), nil
}
