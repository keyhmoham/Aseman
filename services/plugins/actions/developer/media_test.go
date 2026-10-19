package developer

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"strings"
	"sync"
	"testing"

	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/plugins/actions/llm/dto"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
)

// vercelOffering is a model served through Vercel AI Gateway.
func vercelOffering(model, typ string, owner identity.ID, set func(*dto.Offering)) dto.Offering {
	o := dto.Offering{Provider: "vercel-id", Slug: "vercel", Name: "Vercel AI Gateway", Kind: "vercel", IsDefault: true, Owner: owner,
		BaseURL: "https://ai-gateway.vercel.sh/v1", APIKey: "vck-secret", Model: model, Type: typ}
	set(&o)
	return o
}

// mediaHarness serves one model of each kind through a scripted Vercel.
func mediaHarness(t *testing.T) (*fixture, *Principal, string, *sync.Map, identity.ID) {
	f := harness(t)
	owner, _ := identity.New(1)
	f.s.Providers = fakeProviders{list: []dto.Offering{
		vercelOffering("bfl/flux-2-pro", "image", owner, func(o *dto.Offering) { o.PerImage = 96_000 }),
		vercelOffering("alibaba/wan-v2.6-t2v", "video", owner, func(o *dto.Offering) {
			o.PerSecond, o.PerSecondBy = 180_000, map[string]float64{"720p": 120_000, "1080p": 180_000}
		}),
		vercelOffering("fish-audio/s1", "speech", owner, func(o *dto.Offering) { o.PerCharacter = 18 }),
		vercelOffering("openai/whisper-1", "transcription", owner, func(o *dto.Offering) { o.PerSecond = 120 }),
		vercelOffering("cohere/rerank-v3.5", "rerank", owner, func(o *dto.Offering) { o.PerSearch = 2_500 }),
		vercelOffering("voyage/rerank-2.5", "rerank", owner, func(o *dto.Offering) { o.InputPrice = 60_000 }),
	}}
	f.fin.balance[owner] = 0
	seen := &sync.Map{}
	videoState := "pending"
	f.http.handler = func(r *http.Request, body []byte) (int, string, string) {
		seen.Store(r.URL.Path, r.Header.Clone())
		switch r.URL.Path {
		case "/v4/ai/image-model":
			return 200, "application/json", `{"images":["aW1hZ2U="],"warnings":[]}`
		case "/v4/ai/speech-model":
			return 200, "application/json", `{"audio":"` + base64.StdEncoding.EncodeToString([]byte("ID3\x04audio")) + `"}`
		case "/v4/ai/transcription-model":
			return 200, "application/json", `{"text":"Welcome to the meeting.","segments":[],"language":"en","durationInSeconds":30}`
		case "/v2/rerank":
			return 200, "application/json", `{"id":"r1","results":[{"index":1,"relevance_score":0.91},{"index":0,"relevance_score":0.12}],"meta":{"billed_units":{"search_units":1}}}`
		case "/v4/ai/video-model/start":
			return 200, "application/json", `{"operation":{"gatewayJobId":"job_1"}}`
		case "/v4/ai/video-model/status":
			switch videoState {
			case "completed":
				return 200, "application/json", `{"status":"completed","videos":[{"type":"url","url":"https://cdn.test/v.mp4","mediaType":"video/mp4"}]}`
			case "error":
				return 200, "application/json", `{"status":"error","error":"The provider refused the prompt."}`
			}
			return 200, "application/json", `{"status":"pending"}`
		}
		return 404, "application/json", `{"error":"no route"}`
	}
	seen.Store("videoState", func(s string) { videoState = s })
	p, secret := f.key(t, f.personal(t), KeyInput{Name: "app", Permissions: all})
	return f, p, secret, seen, owner
}

func apiCall(t *testing.T, f *fixture, h network.Handler, secret, ctype string, body []byte, params map[string]string) *network.Response {
	t.Helper()
	header := map[string]string{"Authorization": "Bearer " + secret, "Content-Type": ctype}
	if params != nil {
		raw, _ := json.Marshal(params)
		header["x-route-params"] = string(raw)
	}
	resp, err := h(f.ctx, &network.Request{Method: network.MethodPost, Header: header, Body: body})
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func TestImagesSpeechTranscriptionAndRerankThroughVercel(t *testing.T) {
	f, _, secret, seen, owner := mediaHarness(t)

	img := apiCall(t, f, f.s.apiRun(TypeImage), secret, "application/json", []byte(`{"model":"bfl/flux-2-pro","prompt":"a lighthouse","aspect_ratio":"4:3"}`), nil)
	var ib map[string]any
	_ = json.Unmarshal(img.Body, &ib)
	if img.Status != 200 || ib["data"].([]any)[0].(map[string]any)["b64_json"] != "aW1hZ2U=" || ib["usage"].(map[string]any)["cost"] != 0.096 {
		t.Fatalf("image: %d %s", img.Status, img.Body)
	}
	h, _ := seen.Load("/v4/ai/image-model")
	if hdr := h.(http.Header); hdr.Get("ai-model-id") != "bfl/flux-2-pro" || hdr.Get("ai-image-model-specification-version") != "4" || hdr.Get("Authorization") != "Bearer vck-secret" {
		t.Fatalf("Vercel's image protocol: %v", hdr)
	}
	if b := f.http.bodies[len(f.http.bodies)-1]; b["aspectRatio"] != "4:3" || b["n"] != 1.0 || b["prompt"] != "a lighthouse" {
		t.Fatalf("image body: %v", b)
	}

	speech := apiCall(t, f, f.s.apiRun(TypeSpeech), secret, "application/json", []byte(`{"model":"fish-audio/s1","input":"Hello there","voice":"alloy"}`), nil)
	if speech.Status != 200 || string(speech.Body) != "ID3\x04audio" || speech.Header["Content-Type"] != "audio/mpeg" || speech.Header["X-Tradera-Cost"] != "0.000198" {
		t.Fatalf("speech is the audio itself, 11 characters at 18 units: %d %v %q", speech.Status, speech.Header, speech.Body)
	}
	if b := f.http.bodies[len(f.http.bodies)-1]; b["text"] != "Hello there" || b["voice"] != "alloy" {
		t.Fatalf("speech body: %v", b)
	}

	var form bytes.Buffer
	w := multipart.NewWriter(&form)
	_ = w.WriteField("model", "openai/whisper-1")
	fw, _ := w.CreateFormFile("file", "meeting.mp3")
	_, _ = fw.Write([]byte("ID3 pretend audio"))
	_ = w.Close()
	tr := apiCall(t, f, f.s.apiRun(TypeTranscription), secret, w.FormDataContentType(), form.Bytes(), nil)
	var tb map[string]any
	_ = json.Unmarshal(tr.Body, &tb)
	if tr.Status != 200 || tb["text"] != "Welcome to the meeting." || tb["duration"] != 30.0 || tb["usage"].(map[string]any)["cost"] != 0.0036 {
		t.Fatalf("transcription, 30 s at 120 units: %d %s", tr.Status, tr.Body)
	}
	if b := f.http.bodies[len(f.http.bodies)-1]; b["mediaType"] != "audio/mpeg" || b["audio"] != base64.StdEncoding.EncodeToString([]byte("ID3 pretend audio")) {
		t.Fatalf("the upload is sent as base64: %v", b)
	}

	rr := apiCall(t, f, f.s.apiRun(TypeRerank), secret, "application/json", []byte(`{"model":"cohere/rerank-v3.5","query":"capital of France","documents":["Berlin","Paris"],"top_n":2}`), nil)
	var rb map[string]any
	_ = json.Unmarshal(rr.Body, &rb)
	if rr.Status != 200 || len(rb["results"].([]any)) != 2 || rb["usage"].(map[string]any)["cost"] != 0.0025 {
		t.Fatalf("rerank, one search: %d %s", rr.Status, rr.Body)
	}
	if b := f.http.bodies[len(f.http.bodies)-1]; b["model"] != "cohere/rerank-v3.5" || b["query"] != "capital of France" {
		t.Fatalf("rerank goes to the Cohere-compatible endpoint: %v", b)
	}
	voyage := apiCall(t, f, f.s.apiRun(TypeRerank), secret, "application/json", []byte(`{"model":"voyage/rerank-2.5","query":"q","documents":["a"]}`), nil)
	if voyage.Status != 200 || voyage.Header["X-Tradera-Cost"] == "" {
		t.Fatalf("rerank priced by tokens: %d %s", voyage.Status, voyage.Body)
	}

	if f.fin.balance[owner] != 96_000+198+3_600+2_500+1 {
		t.Fatalf("the provider key's owner is paid: %d", f.fin.balance[owner])
	}
	logs, _ := f.s.Logs(f.ctx, f.me, LogFilter{}, 10)
	for _, l := range logs {
		if strings.Contains(jsonString(l.Response), "aW1hZ2U=") {
			t.Fatal("the log keeps no pictures")
		}
	}
	if bad := apiCall(t, f, f.s.apiRun(TypeSpeech), secret, "application/json", []byte(`{"model":"fish-audio/s1"}`), nil); bad.Status != 400 {
		t.Fatalf("speech without input: %d", bad.Status)
	}
	if wrong := apiCall(t, f, f.s.apiRun(TypeSpeech), secret, "application/json", []byte(`{"model":"bfl/flux-2-pro","input":"x"}`), nil); wrong.Status != 400 || !strings.Contains(string(wrong.Body), "/v1/images/generations") {
		t.Fatalf("an image model on the speech endpoint: %d %s", wrong.Status, wrong.Body)
	}
}

func TestVideoIsAJobChargedAtStartAndRefundedIfItFails(t *testing.T) {
	f, _, secret, seen, owner := mediaHarness(t)
	setState, _ := seen.Load("videoState")
	before := f.fin.balance[f.me]

	if bad := apiCall(t, f, f.s.apiVideoStart, secret, "application/json", []byte(`{"model":"alibaba/wan-v2.6-t2v","prompt":"a boat"}`), nil); bad.Status != 400 || !strings.Contains(string(bad.Body), "duration") {
		t.Fatalf("a video needs its length: %d %s", bad.Status, bad.Body)
	}
	start := apiCall(t, f, f.s.apiVideoStart, secret, "application/json", []byte(`{"model":"alibaba/wan-v2.6-t2v","prompt":"a boat","duration":5,"resolution":"720p"}`), nil)
	var sb map[string]any
	_ = json.Unmarshal(start.Body, &sb)
	id, _ := sb["id"].(string)
	if start.Status != 202 || sb["status"] != "pending" || !strings.HasPrefix(id, "vid_") || sb["usage"].(map[string]any)["cost"] != 0.6 {
		t.Fatalf("5 s at 720p, $0.12 a second: %d %s", start.Status, start.Body)
	}
	if b := f.http.bodies[len(f.http.bodies)-1]; b["resolution"] != "1280x720" || b["duration"] != 5.0 || b["prompt"] != "a boat" {
		t.Fatalf("start body: %v", b)
	}
	if f.fin.balance[f.me] != before-600_000 {
		t.Fatalf("charged at the start: %d", before-f.fin.balance[f.me])
	}

	status := func() map[string]any {
		r := apiCall(t, f, f.s.apiVideoStatus, secret, "", nil, map[string]string{"id": id})
		var b map[string]any
		_ = json.Unmarshal(r.Body, &b)
		if r.Status != 200 {
			t.Fatalf("status: %d %s", r.Status, r.Body)
		}
		return b
	}
	if b := status(); b["status"] != "pending" {
		t.Fatalf("pending: %v", b)
	}
	setState.(func(string))("completed")
	if b := status(); b["status"] != "completed" || b["videos"].([]any)[0].(map[string]any)["url"] != "https://cdn.test/v.mp4" {
		t.Fatalf("completed: %v", b)
	}

	// A second video fails: it is refunded once, however often it is asked about.
	setState.(func(string))("pending")
	second := apiCall(t, f, f.s.apiVideoStart, secret, "application/json", []byte(`{"model":"alibaba/wan-v2.6-t2v","prompt":"a storm","duration":4}`), nil)
	_ = json.Unmarshal(second.Body, &sb)
	id = sb["id"].(string)
	if sb["usage"].(map[string]any)["cost"] != 0.72 {
		t.Fatalf("no resolution named: the dearest rate, 4 s at $0.18: %s", second.Body)
	}
	setState.(func(string))("error")
	for i := 0; i < 2; i++ {
		if b := status(); b["status"] != "failed" || !strings.Contains(b["error"].(map[string]any)["message"].(string), "refunded") {
			t.Fatalf("failed: %v", b)
		}
	}
	if f.fin.balance[f.me] != before-600_000 || f.fin.balance[owner] != 600_000 {
		t.Fatalf("the failed video is refunded once: org %d owner %d", before-f.fin.balance[f.me], f.fin.balance[owner])
	}

	if r := apiCall(t, f, f.s.apiVideoStatus, secret, "", nil, map[string]string{"id": "vid_nothing"}); r.Status != 404 {
		t.Fatalf("an unknown video: %d", r.Status)
	}
}

func TestResolutionsAreReadAsHeights(t *testing.T) {
	for in, want := range map[string]int{"720p": 720, "1280x720": 720, "1080P": 1080, "4k": 2160, "3840x2160": 2160, "": 0, "big": 0} {
		if got := resolutionHeight(in); got != want {
			t.Fatalf("%q: %d, want %d", in, got, want)
		}
	}
	o := dto.Offering{PerSecond: 720_000, PerSecondBy: map[string]float64{"720p": 400_000, "4k": 720_000}}
	if videoRate(o, "3840x2160") != 720_000 || videoRate(o, "1280x720") != 400_000 || videoRate(o, "") != 720_000 {
		t.Fatal("a size is matched to its named resolution; none is the dearest")
	}
}
