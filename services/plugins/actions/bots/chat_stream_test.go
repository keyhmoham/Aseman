package bots

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// sse writes OpenAI-style event stream chunks.
func sse(w http.ResponseWriter, chunks ...string) {
	w.Header().Set("Content-Type", "text/event-stream")
	f, _ := w.(http.Flusher)
	for _, c := range chunks {
		fmt.Fprintf(w, "data: %s\n\n", c)
		if f != nil {
			f.Flush()
		}
	}
}

func delta(text string) string {
	return fmt.Sprintf(`{"choices":[{"delta":{"content":%q}}]}`, text)
}

const usageChunk = `{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}`

type server struct {
	*httptest.Server
	hits int32
}

func newServer(t *testing.T, h func(n int32, w http.ResponseWriter, r *http.Request)) *server {
	s := &server{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h(atomic.AddInt32(&s.hits, 1), w, r)
	}))
	t.Cleanup(s.Close)
	return s
}

func (s *server) model(name string) vmm.ProviderConfig {
	return vmm.ProviderConfig{BaseURL: s.URL, APIKey: "k", Model: name}
}

var quick = chatLimits{firstToken: 300 * time.Millisecond, idle: 300 * time.Millisecond}

func run(t *testing.T, models []vmm.ProviderConfig, onText func(string)) (chatResult, error) {
	t.Helper()
	return streamChat(context.Background(), &http.Client{}, models, map[string]any{"messages": []any{}}, quick, onText)
}

func TestTheAnswerArrivesAsItIsWritten(t *testing.T) {
	srv := newServer(t, func(_ int32, w http.ResponseWriter, _ *http.Request) {
		sse(w, delta("Hel"), delta("lo "), delta("there"), usageChunk, "[DONE]")
	})
	var seen []string
	res, err := run(t, []vmm.ProviderConfig{srv.model("m1")}, func(text string) { seen = append(seen, text) })
	if err != nil || res.Text != "Hello there" {
		t.Fatalf("got %q, %v", res.Text, err)
	}
	if len(seen) != 3 || seen[0] != "Hel" || seen[2] != "Hello there" {
		t.Fatalf("the text did not grow piece by piece: %v", seen)
	}
	if res.In != 12 || res.Out != 3 || res.Attempts != 1 {
		t.Fatalf("usage %d/%d attempts %d", res.In, res.Out, res.Attempts)
	}
}

func TestABusyProviderIsAskedAgainBeforeAnyOtherModel(t *testing.T) {
	primary := newServer(t, func(n int32, w http.ResponseWriter, _ *http.Request) {
		if n == 1 {
			w.WriteHeader(503)
			return
		}
		sse(w, delta("second try"), "[DONE]")
	})
	fallback := newServer(t, func(int32, http.ResponseWriter, *http.Request) { t.Error("the fallback was asked") })
	res, err := run(t, []vmm.ProviderConfig{primary.model("m1"), fallback.model("m2")}, nil)
	if err != nil || res.Text != "second try" || atomic.LoadInt32(&primary.hits) != 2 {
		t.Fatalf("got %q, %v after %d tries", res.Text, err, primary.hits)
	}
}

func TestARejectedKeyGoesStraightToTheFallback(t *testing.T) {
	primary := newServer(t, func(_ int32, w http.ResponseWriter, _ *http.Request) { w.WriteHeader(401) })
	fallback := newServer(t, func(_ int32, w http.ResponseWriter, _ *http.Request) { sse(w, delta("from the fallback"), "[DONE]") })
	res, err := run(t, []vmm.ProviderConfig{primary.model("m1"), fallback.model("m2")}, nil)
	if err != nil || res.Text != "from the fallback" || res.Model != "m2" {
		t.Fatalf("got %q from %q, %v", res.Text, res.Model, err)
	}
	if atomic.LoadInt32(&primary.hits) != 1 {
		t.Fatalf("a rejected key was asked %d times", primary.hits)
	}
}

func TestAStalledStartIsTriedAgain(t *testing.T) {
	srv := newServer(t, func(n int32, w http.ResponseWriter, r *http.Request) {
		if n == 1 {
			select { // silence, longer than the first-token limit
			case <-time.After(time.Second):
			case <-r.Context().Done():
			}
			return
		}
		sse(w, delta("recovered"), "[DONE]")
	})
	res, err := run(t, []vmm.ProviderConfig{srv.model("m1")}, nil)
	if err != nil || res.Text != "recovered" || res.Attempts != 2 {
		t.Fatalf("got %q after %d attempts, %v", res.Text, res.Attempts, err)
	}
}

func TestAFailureAfterWordsWereShownKeepsThemAndIsNotRetried(t *testing.T) {
	srv := newServer(t, func(_ int32, w http.ResponseWriter, r *http.Request) {
		sse(w, delta("Half an ans"))
		select { // then nothing more arrives
		case <-time.After(time.Second):
		case <-r.Context().Done():
		}
	})
	fallback := newServer(t, func(int32, http.ResponseWriter, *http.Request) {
		t.Error("the fallback was asked after words were shown")
	})
	res, err := run(t, []vmm.ProviderConfig{srv.model("m1"), fallback.model("m2")}, nil)
	if err == nil {
		t.Fatal("a cut-off answer reported success")
	}
	if res.Text != "Half an ans" || atomic.LoadInt32(&srv.hits) != 1 {
		t.Fatalf("kept %q after %d tries", res.Text, srv.hits)
	}
}

func TestARequestTheModelRefusesGoesToNobodyElse(t *testing.T) {
	primary := newServer(t, func(_ int32, w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(400)
		fmt.Fprint(w, `{"error":{"message":"bad request"}}`)
	})
	fallback := newServer(t, func(int32, http.ResponseWriter, *http.Request) { t.Error("a 400 was handed to the fallback") })
	_, err := run(t, []vmm.ProviderConfig{primary.model("m1"), fallback.model("m2")}, nil)
	if err == nil || !strings.Contains(err.Error(), "400") || atomic.LoadInt32(&primary.hits) != 1 {
		t.Fatalf("err %v after %d tries", err, primary.hits)
	}
}

func TestEveryModelFailingGivesTheLastError(t *testing.T) {
	a := newServer(t, func(_ int32, w http.ResponseWriter, _ *http.Request) { w.WriteHeader(503) })
	b := newServer(t, func(_ int32, w http.ResponseWriter, _ *http.Request) { w.WriteHeader(502) })
	res, err := run(t, []vmm.ProviderConfig{a.model("m1"), b.model("m2")}, nil)
	if err == nil || res.Text != "" || !strings.Contains(err.Error(), "502") {
		t.Fatalf("got %q, %v", res.Text, err)
	}
	if atomic.LoadInt32(&a.hits) != 2 || atomic.LoadInt32(&b.hits) != 1 {
		t.Fatalf("tries: primary %d, fallback %d", a.hits, b.hits)
	}
}
