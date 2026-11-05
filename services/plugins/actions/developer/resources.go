package developer

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"mime"
	"mime/multipart"
	"net/http"
	"strings"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/developer/models"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// apiError maps an error onto the API's status, type and code. What is not a
// refusal on purpose is a fault of ours: it is logged and told generally.
func (s *Service) apiError(err error) (int, string, string, string) {
	var ae *AuthError
	if asAuth(err, &ae) {
		return ae.Status, ae.Type, ae.Code, ae.Message
	}
	// What was said on purpose, without the code in front or the cause behind.
	msg := err.Error()
	var coded *errs.Error
	if errors.As(err, &coded) {
		msg = coded.Message
	}
	switch errs.CodeOf(err) {
	case errs.CodeNotFound:
		return http.StatusNotFound, "not_found_error", "not_found", "No such " + msg + "."
	case errs.CodeInvalidArgument:
		return http.StatusBadRequest, "invalid_request_error", "invalid_request", msg
	case errs.CodeConflict, errs.CodeAlreadyExists:
		return http.StatusConflict, "conflict_error", "conflict", msg
	case errs.CodePermission:
		return http.StatusForbidden, "permission_error", "permission_denied", msg
	case errs.CodeFinance:
		return http.StatusPaymentRequired, "billing_error", "insufficient_funds", msg
	case errs.CodeUnavailable:
		return http.StatusServiceUnavailable, "api_error", "unavailable", msg
	}
	s.L.Warn("developer: an API request failed", "error", err)
	return http.StatusInternalServerError, "api_error", "internal_error", "Something went wrong on our side."
}

func asAuth(err error, target **AuthError) bool {
	for err != nil {
		if ae, ok := err.(*AuthError); ok {
			*target = ae
			return true
		}
		u, ok := err.(interface{ Unwrap() error })
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}

func header(req *network.Request, name string) string {
	for k, v := range req.Header {
		if strings.EqualFold(k, name) {
			return v
		}
	}
	return ""
}

// resource serves an endpoint of a resource (computers, files): the key must
// allow it, the answer is JSON, and the call is logged against the key.
func (s *Service) resource(res, lvl, service string, fn func(ctx context.Context, p *Principal, req *network.Request) (any, int, error)) network.Handler {
	return s.resourceLogged(res, lvl, service, true, fn)
}

// resourceLogged is resource; logBody false keeps the request out of the log
// (for requests that carry secrets, like a workflow run's).
func (s *Service) resourceLogged(res, lvl, service string, logBody bool, fn func(ctx context.Context, p *Principal, req *network.Request) (any, int, error)) network.Handler {
	return func(ctx context.Context, req *network.Request) (*network.Response, error) {
		return s.authenticated(req, func(p *Principal, _ map[string]string) *network.Response {
			started := s.now()
			reqID := requestID()
			var out any
			status := http.StatusOK
			err := p.Need(res, lvl)
			if err == nil {
				out, status, err = fn(ctx, p, req)
			}
			var resp *network.Response
			errText := ""
			if err != nil {
				code, typ, ecode, msg := s.apiError(err)
				status, errText = code, msg
				resp = fromResult(errorBody(code, typ, ecode, msg, reqID, nil))
			} else {
				resp = jsonResponse(status, out, map[string]string{"X-Aseman-Request-Id": reqID})
			}
			request := ""
			if !logBody {
				request = "(not logged)"
			} else if len(req.Body) > 0 && strings.Contains(header(req, "Content-Type"), "json") {
				request = clip(string(req.Body), 2000)
			}
			s.writeLog(context.WithoutCancel(ctx), models.Log{OrgID: p.Org.String(), KeyID: p.Key.ID.String(), KeyName: p.Key.Name, Service: service, Method: string(req.Method),
				Path: strings.TrimPrefix(req.Path, "/dev"), Status: int64(status), LatencyMs: s.now().Sub(started).Milliseconds(), Request: request, Response: clip(string(resp.Body), 1000), Error: errText})
			s.recordUse(context.WithoutCancel(ctx), p, 0)
			return resp
		}), nil
	}
}

func param(req *network.Request, name string) string { return routeParams(req)[name] }

func jsonBody(req *network.Request, into any) error {
	if len(bytes.TrimSpace(req.Body)) == 0 {
		return nil
	}
	if err := json.Unmarshal(req.Body, into); err != nil {
		return errs.InvalidArgument("The request body must be JSON.")
	}
	return nil
}

func usdRate(units int64) float64 { return usd(float64(units)) }

func (s *Service) apiComputerOptions(ctx context.Context, _ *Principal, _ *network.Request) (any, int, error) {
	o, err := s.ComputerOptions(ctx)
	if err != nil {
		return nil, 0, err
	}
	rng := func(r Range) map[string]any {
		return map[string]any{"min": r.Min, "max": r.Max, "step": r.Step, "default": r.Default}
	}
	images := make([]map[string]any, 0, len(o.Images))
	for _, i := range o.Images {
		images = append(images, map[string]any{"id": i.ID, "name": i.Name, "description": i.Description, "includes": i.Includes})
	}
	return map[string]any{
		"cpu": rng(o.CPU), "memory_mb": rng(o.MemoryMB),
		"burst":                   map[string]any{"cpu": o.Burst.CPU, "memory_mb": o.Burst.MemoryMB},
		"images":                  images,
		"idle_stop_minutes":       o.IdleStopMin,
		"max_lifetime_minutes":    o.MaxLifetimeMin,
		"command_timeout_seconds": o.CommandTimeoutSec,
		"max_computers":           MaxComputers,
		"pricing": map[string]any{"per_minute": usdRate(o.Pricing.PerMinute), "per_vcpu_minute": usdRate(o.Pricing.CPUPerMin),
			"per_gb_memory_minute": usdRate(o.Pricing.MemoryPerGBMin), "per_gb_disk_minute": usdRate(o.Pricing.DiskPerGBMin), "disk_gb": float64(o.Pricing.DiskMB) / 1024, "currency": "USD"},
	}, http.StatusOK, nil
}

func computerBody(v ComputerView) map[string]any {
	return map[string]any{"id": v.ID, "name": v.Name, "status": v.Status, "image": v.Image, "cpu": v.Spec.CPU, "memory_mb": v.Spec.MemoryMB,
		"created_at": v.CreatedAt, "last_active_at": v.LastActiveAt, "minutes": v.Minutes}
}

func fileBody(v FileView) map[string]any {
	return map[string]any{"id": v.ID, "name": v.Name, "size": v.Size, "mime": v.Mime, "purpose": v.Purpose, "created_at": v.CreatedAt}
}

func (s *Service) apiComputers() []route {
	get := func(p string, h network.Handler) route { return route{network.MethodGet, apiPrefix + p, h} }
	post := func(p string, h network.Handler) route { return route{network.MethodPost, apiPrefix + p, h} }
	del := func(p string, h network.Handler) route { return route{network.MethodDelete, apiPrefix + p, h} }
	const c, f = "computers", "files"
	r, w := LevelRead, LevelWrite
	return []route{
		get("/computers/options", s.resource(c, r, "computers", s.apiComputerOptions)),
		get("/computers", s.resource(c, r, "computers", func(ctx context.Context, p *Principal, _ *network.Request) (any, int, error) {
			list, err := s.Computers(ctx, p.Org)
			data := make([]map[string]any, 0, len(list))
			for _, v := range list {
				data = append(data, computerBody(v))
			}
			return map[string]any{"object": "list", "data": data}, 200, err
		})),
		post("/computers", s.resource(c, w, "computers", func(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
			var in struct {
				Name     string  `json:"name"`
				Image    string  `json:"image"`
				CPU      float64 `json:"cpu"`
				MemoryMB int64   `json:"memory_mb"`
			}
			if err := jsonBody(req, &in); err != nil {
				return nil, 0, err
			}
			v, err := s.CreateComputer(ctx, p.Org, p.Key.CreatedBy, ComputerInput{Name: in.Name, Image: in.Image, Spec: ComputerSpec{CPU: in.CPU, MemoryMB: in.MemoryMB}})
			if err != nil {
				return nil, 0, err
			}
			return computerBody(*v), http.StatusCreated, nil
		})),
		get("/computers/{id}", s.resource(c, r, "computers", func(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
			v, err := s.Computer(ctx, p.Org, param(req, "id"))
			if err != nil {
				return nil, 0, err
			}
			return computerBody(*v), 200, nil
		})),
		del("/computers/{id}", s.resource(c, w, "computers", func(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
			return map[string]any{"id": param(req, "id"), "deleted": true}, 200, s.DeleteComputer(ctx, p.Org, param(req, "id"))
		})),
		post("/computers/{id}/start", s.resource(c, w, "computers", func(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
			v, err := s.SetComputerStatus(ctx, p.Org, param(req, "id"), computerRunning)
			if err != nil {
				return nil, 0, err
			}
			return computerBody(*v), 200, nil
		})),
		post("/computers/{id}/stop", s.resource(c, w, "computers", func(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
			v, err := s.SetComputerStatus(ctx, p.Org, param(req, "id"), computerStopped)
			if err != nil {
				return nil, 0, err
			}
			return computerBody(*v), 200, nil
		})),
		post("/computers/{id}/exec", s.resource(c, w, "computers", func(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
			var in struct {
				Command string `json:"command"`
				Timeout int64  `json:"timeout"`
			}
			if err := jsonBody(req, &in); err != nil {
				return nil, 0, err
			}
			res, err := s.Exec(ctx, p.Org, param(req, "id"), in.Command, in.Timeout)
			if err != nil {
				return nil, 0, err
			}
			return map[string]any{"stdout": res.Stdout, "stderr": res.Stderr, "exit_code": res.ExitCode, "duration_ms": res.Ms}, 200, nil
		})),
		post("/computers/{id}/upload", s.resource(c, w, "computers", func(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
			var in struct {
				File string `json:"file"`
				Path string `json:"path"`
			}
			if err := jsonBody(req, &in); err != nil {
				return nil, 0, err
			}
			if err := s.UploadToComputer(ctx, p.Org, param(req, "id"), in.File, in.Path); err != nil {
				return nil, 0, err
			}
			return map[string]any{"computer": param(req, "id"), "file": in.File, "uploaded": true}, 200, nil
		})),

		get("/storage", s.resource(f, r, "storage", func(ctx context.Context, p *Principal, _ *network.Request) (any, int, error) {
			info, err := s.Storage(ctx, p.Org)
			if err != nil {
				return nil, 0, err
			}
			return map[string]any{"files": info.Files, "used_bytes": info.UsedBytes, "max_file_bytes": info.MaxFileBytes,
				"price_per_gb_month": usdRate(info.PriceGBMonth), "cost_per_month": usdRate(info.PerMonth), "currency": "USD"}, 200, nil
		})),
		get("/files", s.resource(f, r, "storage", func(ctx context.Context, p *Principal, _ *network.Request) (any, int, error) {
			list, err := s.Files(ctx, p.Org)
			data := make([]map[string]any, 0, len(list))
			for _, v := range list {
				data = append(data, fileBody(v))
			}
			return map[string]any{"object": "list", "data": data}, 200, err
		})),
		post("/files", s.resource(f, w, "storage", func(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
			name, mimeType, purpose, data, err := parseUpload(req)
			if err != nil {
				return nil, 0, err
			}
			v, err := s.Upload(ctx, p.Org, name, mimeType, purpose, data)
			if err != nil {
				return nil, 0, err
			}
			return fileBody(*v), http.StatusCreated, nil
		})),
		get("/files/{id}", s.resource(f, r, "storage", func(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
			v, err := s.File(ctx, p.Org, param(req, "id"))
			if err != nil {
				return nil, 0, err
			}
			return fileBody(*v), 200, nil
		})),
		get("/files/{id}/content", s.fileContentAPI),
		del("/files/{id}", s.resource(f, w, "storage", func(ctx context.Context, p *Principal, req *network.Request) (any, int, error) {
			return map[string]any{"id": param(req, "id"), "deleted": true}, 200, s.DeleteFile(ctx, p.Org, param(req, "id"))
		})),
	}
}

// fileContentAPI serves a file's bytes with their own content type.
func (s *Service) fileContentAPI(ctx context.Context, req *network.Request) (*network.Response, error) {
	return s.authenticated(req, func(p *Principal, _ map[string]string) *network.Response {
		reqID := requestID()
		if err := p.Need("files", LevelRead); err != nil {
			return denied(err, reqID)
		}
		f, data, err := s.ReadFile(ctx, p.Org, param(req, "id"))
		if err != nil {
			code, typ, ecode, msg := s.apiError(err)
			return fromResult(errorBody(code, typ, ecode, msg, reqID, nil))
		}
		return &network.Response{Status: 200, Body: data, Header: map[string]string{"Content-Type": f.Mime, "X-Aseman-Request-Id": reqID,
			"Content-Disposition": "attachment; filename=" + quoteFilename(f.Name)}}
	}), nil
}

func quoteFilename(name string) string {
	return "\"" + strings.NewReplacer("\"", "", "\\", "", "\r", "", "\n", "").Replace(name) + "\""
}

// parseUpload reads a multipart form: the `file` and an optional `purpose`.
func parseUpload(req *network.Request) (name, mimeType, purpose string, data []byte, err error) {
	mediaType, params, perr := mime.ParseMediaType(header(req, "Content-Type"))
	if perr != nil || !strings.HasPrefix(mediaType, "multipart/") || params["boundary"] == "" {
		return "", "", "", nil, errs.InvalidArgument("Send the file as multipart form data, in a field called file.")
	}
	reader := multipart.NewReader(bytes.NewReader(req.Body), params["boundary"])
	found := false
	for {
		part, perr := reader.NextPart()
		if perr != nil {
			break
		}
		buf := new(bytes.Buffer)
		if _, cerr := buf.ReadFrom(part); cerr != nil {
			return "", "", "", nil, errs.InvalidArgument("The upload could not be read.")
		}
		switch part.FormName() {
		case "file":
			name, mimeType, data, found = part.FileName(), part.Header.Get("Content-Type"), buf.Bytes(), true
			if mimeType == "application/octet-stream" {
				mimeType = ""
			}
		case "purpose":
			purpose = strings.TrimSpace(buf.String())
		}
	}
	if !found {
		return "", "", "", nil, errs.InvalidArgument("The upload needs a file field.")
	}
	return name, mimeType, purpose, data, nil
}
