package deepagents

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func streamTestAdapter(t *testing.T, handler http.HandlerFunc) (*Adapter, func()) {
	t.Helper()
	provider := httptest.NewServer(handler)
	a, _, _ := newTestAdapter(t)
	a.platform = fakePlatform{provider: vmm.ProviderConfig{BaseURL: provider.URL, Model: "stream-model"}}
	def, err := a.agent(onlyVM(t, a))
	if err != nil {
		t.Fatal(err)
	}
	a.sessions["tok"] = &session{token: "tok", def: def, base: context.Background()}
	return a, provider.Close
}

func streamRequest() *network.Request {
	return &network.Request{
		Header: map[string]string{"Authorization": "Bearer tok"},
		Body:   []byte(`{"model":"stream-model","stream":true,"messages":[{"role":"user","content":"hi"}]}`),
	}
}

func TestServeChatReturnsAtDoneWhenProviderKeepsConnectionOpen(t *testing.T) {
	a, closeProvider := streamTestAdapter(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3}}\n\ndata: [DONE]\n\n")
		w.(http.Flusher).Flush()
		<-r.Context().Done() // the client must finish without waiting for this handler
	})
	defer closeProvider()
	a.llmFirstEventTimeout = time.Second
	a.llmStreamIdleTimeout = time.Second

	done := make(chan *network.Response, 1)
	go func() {
		resp, _ := a.serveChat(context.Background(), streamRequest())
		done <- resp
	}()
	select {
	case resp := <-done:
		if resp.Status != http.StatusOK || !strings.Contains(string(resp.Body), "[DONE]") {
			t.Fatalf("serveChat = %d %s", resp.Status, resp.Body)
		}
	case <-time.After(250 * time.Millisecond):
		t.Fatal("serveChat waited for provider EOF after [DONE]")
	}
}

func TestServeChatReportsFirstEventTimeout(t *testing.T) {
	a, closeProvider := streamTestAdapter(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	})
	defer closeProvider()
	a.llmFirstEventTimeout = 20 * time.Millisecond
	a.llmStreamIdleTimeout = time.Second

	resp, err := a.serveChat(context.Background(), streamRequest())
	if err != nil || resp.Status != http.StatusGatewayTimeout || !strings.Contains(string(resp.Body), "first event") {
		t.Fatalf("serveChat first-event timeout = %v %d %s", err, resp.Status, resp.Body)
	}
}

func TestServeChatReportsResponseHeaderTimeout(t *testing.T) {
	release := make(chan struct{})
	a, closeProvider := streamTestAdapter(t, func(_ http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-release:
		}
	})
	defer func() {
		close(release)
		closeProvider()
	}()
	a.llmFirstEventTimeout = 20 * time.Millisecond

	resp, err := a.serveChat(context.Background(), streamRequest())
	if err != nil || resp.Status != http.StatusGatewayTimeout || !strings.Contains(string(resp.Body), "start responding") {
		t.Fatalf("serveChat response timeout = %v %d %s", err, resp.Status, resp.Body)
	}
}

func TestServeChatReportsStreamIdleTimeout(t *testing.T) {
	a, closeProvider := streamTestAdapter(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = io.WriteString(w, "data: {\"choices\":[{\"delta\":{\"content\":\"started\"}}]}\n\n")
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	})
	defer closeProvider()
	a.llmFirstEventTimeout = time.Second
	a.llmStreamIdleTimeout = 20 * time.Millisecond

	resp, err := a.serveChat(context.Background(), streamRequest())
	if err != nil || resp.Status != http.StatusGatewayTimeout || !strings.Contains(string(resp.Body), "idle timeout") {
		t.Fatalf("serveChat idle timeout = %v %d %s", err, resp.Status, resp.Body)
	}
}
