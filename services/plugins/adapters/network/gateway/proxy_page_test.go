package apihttp

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	network "github.com/aseman/aseman/plugins/adapters/network/ports"
)

func pageRequest(id identity.ID, rest, method string, body any) *network.Request {
	params, _ := json.Marshal(map[string]string{"id": id.String(), "*": rest})
	req := &network.Request{Method: network.Method(method), Header: map[string]string{"x-route-params": string(params), "Authorization": "Bearer test-session"}}
	if body != nil {
		req.Body, _ = json.Marshal(body)
	}
	return req
}

func TestPreviewServesPageAPIAndCallsToolsAsThePerson(t *testing.T) {
	id := identity.ID{Node: 1, Entity: 2}
	space := identity.ID{Node: 1, Entity: 3}
	p := &proxy.Proxy{Entity: entity.Entity{ID: id}, SpaceID: space, TargetURL: "http://127.0.0.1:1", Token: "tunnel"}
	var calls []string
	a := &API{Auth: &previewAuth{valid: true}, Spaces: &previewSpaces{p: p, member: true}}
	a.pageActions = func(_ context.Context, ns, action string, req *api.ActionRequest) (*api.ActionResponse, error) {
		calls = append(calls, ns+"."+action+" "+string(req.Body))
		switch ns + "." + action {
		case "spaces.tools_list":
			return &api.ActionResponse{Status: 200, Body: []byte(`{"tools":[{"name":"sandbox_exec"},{"name":"Weather","bot_id":"w1","frontend":"static","commands":[{"name":"forecast"}]}]}`)}, nil
		case "spaces.bots_list":
			return &api.ActionResponse{Status: 200, Body: []byte(`{"bots":[{"id":"a1","name":"Research","kind":"agent","description":"lab agent","status":"running"},{"id":"w1","name":"Weather","kind":"tool"}]}`)}, nil
		case "spaces.ask":
			if !strings.Contains(string(req.Body), `"bot":"a1"`) || !strings.Contains(string(req.Body), "hello") {
				return &api.ActionResponse{Status: 400, Body: []byte(`{"error":"bad ask","code":"invalid_argument"}`)}, nil
			}
			return &api.ActionResponse{Status: 200, Body: []byte(`{"bot_id":"a1","reply":"Hello from Research"}`)}, nil
		case "tools.invoke":
			body := `{"result":{"temp":21}}`
			if strings.Contains(string(req.Body), `"function":"search"`) {
				// MCP envelope: App UIs must receive unwrapped text, not content[].
				body = `{"result":{"content":[{"type":"text","text":"Title: Oslo\nURL: https://example.org/oslo"}]}}`
			}
			return &api.ActionResponse{Status: 200, Body: []byte(body)}, nil
		}
		return &api.ActionResponse{Status: 404, Body: []byte(`{"error":"nope","code":"not_found"}`)}, nil
	}

	// Preview pages expose tool microtool APIs; interactive UIs use appui_create (DeskWeb).
	resp, err := a.proxyServe(context.Background(), pageRequest(id, "_aseman/api/tools", "GET", nil))
	if err != nil || resp.Status != 200 || strings.Contains(string(resp.Body), "sandbox_exec") || !strings.Contains(string(resp.Body), `"id":"w1"`) {
		t.Fatalf("tools: %+v %v", resp, err)
	}

	resp, err = a.proxyServe(context.Background(), pageRequest(id, "_aseman/kit/openui/openui.js", "GET", nil))
	if err != nil || resp.Status != 200 || !strings.Contains(string(resp.Body), "AsemanOpenUI") {
		t.Fatalf("openui kit: %+v %v", resp, err)
	}
	if ct := resp.Header["Content-Type"]; !strings.Contains(ct, "javascript") {
		t.Fatalf("openui content-type %q", ct)
	}
	resp, err = a.proxyServe(context.Background(), pageRequest(id, "_aseman/kit/openui/catalog.js", "GET", nil))
	if err != nil || resp.Status != 200 || !strings.Contains(string(resp.Body), "AsemanOpenUICatalog") {
		t.Fatalf("openui catalog: %+v %v", resp, err)
	}
	resp, err = a.proxyServe(context.Background(), pageRequest(id, "_aseman/kit/openui/catalog.spec.json", "GET", nil))
	if err != nil || resp.Status != 200 || !strings.Contains(string(resp.Body), `"AppShell"`) {
		t.Fatalf("openui catalog.spec: %+v %v", resp, err)
	}

	resp, err = a.proxyServe(context.Background(), pageRequest(id, "_aseman/api/call", "POST", map[string]any{"tool": "weather", "microtool": "forecast", "args": map[string]any{"city": "Oslo"}}))
	if err != nil || resp.Status != 200 || !strings.Contains(string(resp.Body), `"temp":21`) {
		t.Fatalf("call: %+v %v", resp, err)
	}
	last := calls[len(calls)-1]
	if !strings.HasPrefix(last, "tools.invoke") || !strings.Contains(last, `"bot":"w1"`) || !strings.Contains(last, `"space":"`+space.String()+`"`) || !strings.Contains(last, `"city":"Oslo"`) {
		t.Fatalf("invoke body %s", last)
	}

	resp, err = a.proxyServe(context.Background(), pageRequest(id, "_aseman/api/call", "POST", map[string]any{"tool": "weather", "microtool": "search", "args": map[string]any{"q": "oslo"}}))
	if err != nil || resp.Status != 200 || strings.Contains(string(resp.Body), `"content"`) || !strings.Contains(string(resp.Body), `Title: Oslo`) {
		t.Fatalf("mcp unwrap: %+v %v body=%s", resp, err, string(resp.Body))
	}

	// An unknown tool is an error the page can show, as JSON.
	resp, err = a.proxyServe(context.Background(), pageRequest(id, "_aseman/api/call", "POST", map[string]any{"tool": "nope", "microtool": "x"}))
	if err != nil || resp.Status == 200 || !strings.Contains(string(resp.Body), "Weather") {
		t.Fatalf("unknown tool: %+v %v", resp, err)
	}

	resp, err = a.proxyServe(context.Background(), pageRequest(id, "_aseman/api/agents", "GET", nil))
	if err != nil || resp.Status != 200 || !strings.Contains(string(resp.Body), `"Research"`) || strings.Contains(string(resp.Body), `"Weather"`) {
		t.Fatalf("agents: %+v %v body=%s", resp, err, string(resp.Body))
	}
	resp, err = a.proxyServe(context.Background(), pageRequest(id, "_aseman/api/ask", "POST", map[string]any{"agent": "research", "prompt": "hello"}))
	if err != nil || resp.Status != 200 || !strings.Contains(string(resp.Body), "Hello from Research") {
		t.Fatalf("ask: %+v %v body=%s", resp, err, string(resp.Body))
	}

	// Another site cannot call tools with the person's preview cookie.
	req := pageRequest(id, "_aseman/api/call", "POST", map[string]any{"tool": "weather", "microtool": "forecast"})
	delete(req.Header, "Authorization")
	req.Header["Cookie"] = "oc_proxy_" + id.String() + "=dGVzdC1zZXNzaW9u"
	req.Header["Sec-Fetch-Site"] = "cross-site"
	if _, err = a.proxyServe(context.Background(), req); err == nil {
		t.Fatal("cross-site call accepted")
	}
	req.Header["Sec-Fetch-Site"] = "same-origin"
	if resp, err = a.proxyServe(context.Background(), req); err != nil || resp.Status != http.StatusOK {
		t.Fatalf("same-origin call: %+v %v", resp, err)
	}
}
