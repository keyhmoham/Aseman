package http

import (
	"context"
	"io"
	nethttp "net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

func serve(t *testing.T, a *Adapter, host, path string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(nethttp.MethodGet, "http://"+host+path, nil)
	rec := httptest.NewRecorder()
	a.dispatch(rec, req)
	return rec
}

func adapter(t *testing.T) *Adapter {
	t.Helper()
	a := New(logger.Global())
	a.developerHost = "api.example.com"
	say := func(text string) network.Handler {
		return func(_ context.Context, req *network.Request) (*network.Response, error) {
			return &network.Response{Status: 200, Body: []byte(text + " " + req.Path + " host=" + req.Host)}, nil
		}
	}
	for method, routes := range map[network.Method]map[string]string{
		network.MethodGet: {"/dev/v1/models": "developer", "/v1/auth/whoami": "internal", "/healthz": "health"},
	} {
		for pattern, text := range routes {
			if err := a.Handle(method, pattern, say(text)); err != nil {
				t.Fatal(err)
			}
		}
	}
	return a
}

func TestDeveloperHostServesOnlyTheDeveloperAPI(t *testing.T) {
	a := adapter(t)
	if rec := serve(t, a, "api.example.com", "/v1/models"); rec.Code != 200 || !strings.HasPrefix(rec.Body.String(), "developer /dev/v1/models host=api.example.com") {
		t.Fatalf("the developer host's /v1 is the developer API: %d %s", rec.Code, rec.Body)
	}
	if rec := serve(t, a, "api.example.com:443", "/v1/auth/whoami"); rec.Code != 404 {
		t.Fatalf("the internal actions are not reachable on the developer host: %d %s", rec.Code, rec.Body)
	}
	if rec := serve(t, a, "api.example.com", "/healthz"); rec.Code != 200 {
		t.Fatalf("health: %d", rec.Code)
	}
	if rec := serve(t, a, "connect.example.com", "/v1/auth/whoami"); rec.Code != 200 || !strings.HasPrefix(rec.Body.String(), "internal") {
		t.Fatalf("the node's own host is unchanged: %d %s", rec.Code, rec.Body)
	}
	if rec := serve(t, a, "connect.example.com", "/dev/v1/models"); rec.Code != 404 {
		t.Fatalf("the developer routes have one address: %d %s", rec.Code, rec.Body)
	}
	if rec := serve(t, a, "connect.example.com", "/v1/models"); rec.Code != 404 {
		t.Fatalf("/v1/models is not a node action: %d", rec.Code)
	}
}

func TestForwardedHostIsBelieved(t *testing.T) {
	a := adapter(t)
	req := httptest.NewRequest(nethttp.MethodGet, "http://node:8080/v1/models", nil)
	req.Header.Set("X-Forwarded-Host", "API.example.com")
	rec := httptest.NewRecorder()
	a.dispatch(rec, req)
	if rec.Code != 200 || !strings.HasPrefix(rec.Body.String(), "developer") {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
}

func TestWithoutADeveloperHostNothingChanges(t *testing.T) {
	a := adapter(t)
	a.developerHost = ""
	if rec := serve(t, a, "anything.test", "/dev/v1/models"); rec.Code != 200 {
		t.Fatalf("the prefix is reachable for local development: %d", rec.Code)
	}
	if rec := serve(t, a, "anything.test", "/v1/models"); rec.Code != 404 {
		t.Fatalf("%d", rec.Code)
	}
}

func TestStreamedResponsesReachTheCallerAsTheyAreWritten(t *testing.T) {
	a := New(logger.Global())
	release := make(chan struct{})
	if err := a.Handle(network.MethodGet, "/events", func(context.Context, *network.Request) (*network.Response, error) {
		return &network.Response{Status: 200, Header: map[string]string{"Content-Type": "text/event-stream"}, Stream: func(_ context.Context, w io.Writer) error {
			_, _ = io.WriteString(w, "data: one\n\n")
			<-release
			_, _ = io.WriteString(w, "data: two\n\n")
			return nil
		}}, nil
	}); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(nethttp.HandlerFunc(a.dispatch))
	defer srv.Close()
	resp, err := nethttp.Get(srv.URL + "/events")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	buf := make([]byte, 64)
	n, _ := resp.Body.Read(buf)
	if !strings.Contains(string(buf[:n]), "data: one") {
		t.Fatalf("the first event arrives before the stream ends: %q", buf[:n])
	}
	close(release)
	rest, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(rest), "data: two") || resp.Header.Get("Content-Type") != "text/event-stream" {
		t.Fatalf("%q %v", rest, resp.Header)
	}
}
