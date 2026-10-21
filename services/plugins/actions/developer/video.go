package developer

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// Video generation takes minutes, so it is a job: POST /videos/generations
// starts it at the provider and answers with its id at once; GET
// /videos/{id} asks the provider how it is going and hands over the videos
// when they are done. A video is charged when it starts (seconds × the
// model's rate at the resolution asked for) and refunded if the provider
// fails it.

// maxVideoSeconds bounds the length a request may ask for.
const maxVideoSeconds = 60

const videoPrefix = "vid_"

// videoInput is what a video request asks for.
type videoInput struct {
	Seconds    int64
	Resolution string
	Body       map[string]any
}

// parseVideo reads a video request into the provider's start request.
func parseVideo(body map[string]any) (videoInput, string) {
	in := videoInput{Body: map[string]any{"n": 1}}
	prompt, _ := body["prompt"].(string)
	if strings.TrimSpace(prompt) == "" {
		return in, "`prompt` is required."
	}
	in.Body["prompt"] = prompt
	seconds, _ := body["duration"].(float64)
	if seconds < 1 || seconds > maxVideoSeconds || seconds != float64(int64(seconds)) {
		return in, fmt.Sprintf("`duration` is required: the video's length in whole seconds, 1 to %d. It decides the price.", maxVideoSeconds)
	}
	in.Seconds = int64(seconds)
	in.Body["duration"] = in.Seconds
	if r, _ := body["resolution"].(string); r != "" {
		if resolutionHeight(r) == 0 {
			return in, "`resolution` is a size such as 1280x720, or 720p."
		}
		in.Resolution = r
		if !strings.Contains(r, "x") {
			// The provider takes a size; a named resolution is sent as the 16:9 one.
			h := resolutionHeight(r)
			r = fmt.Sprintf("%dx%d", h*16/9/2*2, h)
		}
		in.Body["resolution"] = r
	}
	for from, to := range map[string]string{"aspect_ratio": "aspectRatio", "seed": "seed", "generate_audio": "generateAudio", "fps": "fps", "provider_options": "providerOptions"} {
		if v, ok := body[from]; ok && v != nil {
			in.Body[to] = v
		}
	}
	// A starting image: a URL, or a data URL of the image itself.
	if img, _ := body["image"].(string); img != "" {
		switch {
		case strings.HasPrefix(img, "https://") || strings.HasPrefix(img, "http://"):
			in.Body["image"] = map[string]any{"type": "url", "url": img}
		case strings.HasPrefix(img, "data:"):
			comma := strings.IndexByte(img, ',')
			meta := img[5:max(comma, 5)]
			if comma < 0 || !strings.HasSuffix(meta, ";base64") {
				return in, "`image` is a URL, or a base64 data URL (data:image/png;base64,...)."
			}
			in.Body["image"] = map[string]any{"type": "file", "mediaType": strings.TrimSuffix(meta, ";base64"), "data": img[comma+1:]}
		default:
			return in, "`image` is a URL, or a base64 data URL (data:image/png;base64,...)."
		}
	}
	return in, ""
}

func (s *Service) apiVideoStart(ctx context.Context, req *network.Request) (*network.Response, error) {
	return s.authenticated(req, func(p *Principal, _ map[string]string) *network.Response {
		reqID := requestID()
		var body map[string]any
		if err := json.Unmarshal(req.Body, &body); err != nil || body == nil {
			return fromResult(errorBody(400, "invalid_request_error", "invalid_json", "The request body must be a JSON object.", reqID, nil))
		}
		c, bad := parseCall(TypeVideo, body)
		if bad != "" {
			return fromResult(errorBody(400, "invalid_request_error", "invalid_request", bad, reqID, nil))
		}
		in, bad := parseVideo(body)
		if bad != "" {
			return fromResult(errorBody(400, "invalid_request_error", "invalid_request", bad, reqID, nil))
		}
		c.Principal, c.Org, c.KeyID, c.KeyName = p, p.Org, p.Key.ID.String(), p.Key.Name
		return fromResult(s.StartVideo(ctx, c, in))
	}), nil
}

// StartVideo starts a video at the first provider that takes it, charges for
// it and records the job.
func (s *Service) StartVideo(ctx context.Context, c Call, in videoInput) *Result {
	started := s.now()
	reqID := requestID()
	logCall := func(res *Result, model, provider string, cost int64, response any, errText string) {
		res.LogID = s.writeLog(context.WithoutCancel(ctx), models.Log{OrgID: c.Org.String(), KeyID: c.KeyID, KeyName: c.KeyName, Service: "models", Method: "POST",
			Path: publicPath[TypeVideo], Status: int64(res.Status), LatencyMs: s.now().Sub(started).Milliseconds(), Model: model, Provider: provider,
			RequestedModel: c.Model, Cost: cost, Request: clip(jsonString(c.requestView()), 4000), Response: clip(jsonString(response), 4000), Error: errText})
		if c.Principal != nil {
			s.recordUse(context.WithoutCancel(ctx), c.Principal, cost)
		}
	}
	refuse := func(status int, typ, code, message string) *Result {
		r := errorBody(status, typ, code, message, reqID, nil)
		logCall(r, c.Model, "", 0, nil, message)
		return r
	}
	if c.Principal != nil {
		if err := c.Principal.Need("chat", LevelWrite); err != nil {
			return refuse(403, "permission_error", "permission_denied", err.Error())
		}
		if err := s.SpendCheck(ctx, c.Principal); err != nil {
			if ae, ok := err.(*AuthError); ok {
				return refuse(ae.Status, ae.Type, ae.Code, ae.Message)
			}
			return refuse(500, "api_error", "internal_error", "Could not check the spending limits.")
		}
	}
	catalog, err := s.Catalog(ctx)
	if err != nil {
		return refuse(503, "api_error", "catalog_unavailable", "The model catalog is unavailable right now.")
	}
	plan, denied := allowed(c.Principal, PlanRoute(catalog, c.Model, c.Route, c.Fallbacks))
	var attempts []Attempt
	for _, a := range plan.Attempts {
		if a.Model.Type == TypeVideo {
			attempts = append(attempts, a)
		}
	}
	if len(attempts) == 0 {
		if first := FindModel(catalog, firstRef(c.Model)); first != nil && first.Type != TypeVideo && denied == "" {
			return refuse(400, "invalid_request_error", "wrong_model_type", fmt.Sprintf("%s is a %s model: use POST %s.", first.ID, first.Type, publicPath[first.Type]))
		}
		if denied != "" {
			return refuse(403, "permission_error", "model_not_allowed", denied)
		}
		return refuse(404, "not_found_error", "model_not_found", "No video model named "+firstRef(c.Model)+". List them with GET /v1/models?type=video.")
	}
	var skipped []attemptNote
	for _, a := range attempts {
		o := a.Endpoint.offering
		cost := costOf(TypeVideo, a.Endpoint, Usage{Seconds: float64(in.Seconds), Resolution: in.Resolution})
		if err := s.Fin.EnsureFunds(ctx, c.Org, max(cost, minFunds)); err != nil {
			return refuse(402, "billing_error", "insufficient_funds", fmt.Sprintf("This video costs $%.2f and the organization's balance is too low. Add funds under Billing in the console.", usd(float64(cost))))
		}
		if !isVercel(o) {
			skipped = append(skipped, attemptNote{a.Endpoint.Provider, a.Model.ID, 0, errNotServed.Error()})
			continue
		}
		up, err := vercelModelRequest(ctx, o, "video", "/start", in.Body)
		if err != nil {
			skipped = append(skipped, attemptNote{a.Endpoint.Provider, a.Model.ID, 0, err.Error()})
			continue
		}
		resp, err := s.HTTP.Do(up)
		if err != nil {
			skipped = append(skipped, attemptNote{a.Endpoint.Provider, a.Model.ID, 0, "could not reach the provider"})
			continue
		}
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		_ = resp.Body.Close()
		if resp.StatusCode >= 300 {
			if retryable(resp.StatusCode) {
				skipped = append(skipped, attemptNote{a.Endpoint.Provider, a.Model.ID, resp.StatusCode, upstreamMessage(data)})
				continue
			}
			r := errorBody(resp.StatusCode, "invalid_request_error", "upstream_rejected", upstreamMessage(data), reqID, nil)
			logCall(r, a.Model.ID, a.Endpoint.Provider, 0, nil, upstreamMessage(data))
			return r
		}
		var started struct {
			Operation json.RawMessage `json:"operation"`
		}
		if json.Unmarshal(data, &started) != nil || len(started.Operation) == 0 || string(started.Operation) == "null" {
			skipped = append(skipped, attemptNote{a.Endpoint.Provider, a.Model.ID, 0, "the provider's reply could not be read"})
			continue
		}
		id, err := identity.New(s.K.NodeID())
		if err != nil {
			return refuse(500, "api_error", "internal_error", "Something went wrong on our side.")
		}
		job := &models.VideoJob{Entity: entity.Entity{ID: id, CreatedAt: s.now(), UpdatedAt: s.now()}, OrgID: c.Org, KeyID: c.KeyID, KeyName: c.KeyName,
			Model: a.Model.ID, Provider: a.Endpoint.Provider, Operation: string(started.Operation), Status: models.VideoPending,
			Seconds: in.Seconds, Resolution: in.Resolution, Cost: cost, Payee: o.Owner}
		if err := s.R.CreateID(ctx, "dev_videos", id, job); err != nil {
			// The provider is already making it: it is billed, so it is not lost.
			s.L.Warn("developer: could not record a video job", "error", err)
		}
		s.bill(ctx, c, a, cost)
		view := videoView(job, nil)
		if len(skipped) > 0 {
			view["fallbacks_used"] = publicAttempts(skipped)
		}
		body, _ := json.Marshal(view)
		res := &Result{Status: http.StatusAccepted, Body: body, Model: a.Model.ID, Provider: a.Endpoint.Provider, Cost: cost, Skipped: skipped,
			Header: map[string]string{"Content-Type": "application/json", "X-Aseman-Model": a.Model.ID, "X-Aseman-Request-Id": reqID}}
		logCall(res, a.Model.ID, a.Endpoint.Provider, cost, view, "")
		return res
	}
	r := errorBody(502, "api_error", "model_unavailable", "The model could not make this video. Try again, or add fallback models.", reqID, map[string]any{"attempts": publicAttempts(skipped)})
	r.Skipped = skipped
	logCall(r, c.Model, "", 0, nil, "all providers failed")
	return r
}

// videoView is a job as the API shows it.
func videoView(j *models.VideoJob, videos []map[string]any) map[string]any {
	out := map[string]any{"id": videoPrefix + j.ID.String(), "object": "video", "status": j.Status, "model": j.Model,
		"duration": j.Seconds, "created_at": j.CreatedAt.Unix(), "usage": map[string]any{"seconds": j.Seconds, "cost": usd(float64(j.Cost))}}
	if j.Resolution != "" {
		out["resolution"] = j.Resolution
	}
	if j.Error != "" {
		out["error"] = map[string]any{"message": j.Error}
	}
	if videos != nil {
		out["videos"] = videos
	}
	return out
}

func (s *Service) apiVideoStatus(ctx context.Context, req *network.Request) (*network.Response, error) {
	return s.authenticated(req, func(p *Principal, _ map[string]string) *network.Response {
		reqID := requestID()
		if err := p.Need("chat", LevelWrite); err != nil {
			return denied(err, reqID)
		}
		raw := strings.TrimPrefix(routeParams(req)["id"], videoPrefix)
		id, err := identity.Parse(raw)
		var job models.VideoJob
		if err == nil {
			err = s.R.Get(ctx, "dev_videos", id, &job)
		}
		if err != nil || job.OrgID != p.Org {
			return fromResult(errorBody(404, "not_found_error", "not_found", "No video with that id.", reqID, nil))
		}
		view, err := s.VideoStatus(ctx, &job)
		if err != nil {
			return fromResult(errorBody(502, "api_error", "provider_error", err.Error(), reqID, nil))
		}
		return jsonResponse(http.StatusOK, view, map[string]string{"X-Aseman-Request-Id": reqID})
	}), nil
}

// VideoStatus asks the provider how a job is going. A finished video is
// handed over as the provider gives it: a URL to download (it expires) or the
// bytes in base64. A failed one is refunded, once.
func (s *Service) VideoStatus(ctx context.Context, job *models.VideoJob) (map[string]any, error) {
	if job.Status == models.VideoFailed {
		return videoView(job, nil), nil
	}
	catalog, err := s.Catalog(ctx)
	if err != nil {
		return nil, fmt.Errorf("the model catalog is unavailable right now")
	}
	var endpoint *Endpoint
	if m := FindModel(catalog, job.Model); m != nil {
		for i := range m.Endpoints {
			if m.Endpoints[i].Provider == job.Provider {
				endpoint = &m.Endpoints[i]
			}
		}
	}
	if endpoint == nil {
		return nil, fmt.Errorf("the provider that is making this video is no longer available")
	}
	up, err := vercelModelRequest(ctx, endpoint.offering, "video", "/status", map[string]any{"operation": json.RawMessage(job.Operation)})
	if err != nil {
		return nil, err
	}
	resp, err := s.HTTP.Do(up)
	if err != nil {
		return nil, fmt.Errorf("could not reach the provider")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 512<<20))
	if err != nil {
		return nil, fmt.Errorf("the provider's reply was cut short")
	}
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("the provider answered %d: %s", resp.StatusCode, upstreamMessage(data))
	}
	var st struct {
		Status string           `json:"status"`
		Error  string           `json:"error"`
		Videos []map[string]any `json:"videos"`
	}
	if json.Unmarshal(data, &st) != nil {
		return nil, fmt.Errorf("the provider's reply could not be read")
	}
	switch st.Status {
	case "completed":
		videos := make([]map[string]any, 0, len(st.Videos))
		for _, v := range st.Videos {
			mt, _ := v["mediaType"].(string)
			switch v["type"] {
			case "url":
				videos = append(videos, map[string]any{"url": v["url"], "media_type": mt})
			case "base64":
				videos = append(videos, map[string]any{"b64_json": v["data"], "media_type": mt})
			}
		}
		s.settleVideo(ctx, job, models.VideoCompleted, "")
		return videoView(job, videos), nil
	case "error", "cancelled":
		msg := st.Error
		if msg == "" {
			msg = "The provider cancelled the video."
		}
		s.settleVideo(ctx, job, models.VideoFailed, msg)
		return videoView(job, nil), nil
	}
	return videoView(job, nil), nil
}

// settleVideo records how a job ended, once; a failed job is refunded.
func (s *Service) settleVideo(ctx context.Context, job *models.VideoJob, status, errText string) {
	if job.Status != models.VideoPending {
		return
	}
	next := *job
	next.Status, next.Error, next.UpdatedAt = status, clip(errText, 400), s.now()
	if status == models.VideoFailed && job.Cost > 0 && job.Payee != job.OrgID && !job.Payee.IsZero() {
		next.Error = strings.TrimSpace(next.Error + " The charge was refunded.")
	}
	changed, err := s.R.CompareAndSwap(ctx, "dev_videos", job.ID.String(), map[string]any{"status": models.VideoPending}, &next)
	if err != nil {
		s.L.Warn("developer: could not record how a video ended", "video", job.ID.String(), "error", err)
		return
	}
	*job = next
	// No money moved when the organization pays itself (the node's owner on its own key).
	if !changed || status != models.VideoFailed || job.Cost <= 0 || job.Payee == job.OrgID || job.Payee.IsZero() {
		return
	}
	if _, err := s.Fin.Transfer(context.WithoutCancel(ctx), job.Payee, job.OrgID, job.Cost); err != nil {
		s.L.Error("developer: could not refund a failed video", "video", job.ID.String(), "org", job.OrgID.String(), "cost", job.Cost, "error", err)
	}
}
