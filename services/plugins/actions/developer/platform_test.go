package developer

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

func TestPlatformAllowsProductActionsAndDeniesAdmin(t *testing.T) {
	for _, tc := range []struct {
		ns, action string
		ok         bool
	}{
		{"spaces", "message_send", true},
		{"bots", "bot_list", true},
		{"tools", "invoke", true},
		{"finance", "account", true},
		{"users", "notifications_list", true},
		{"themes", "get", true},
		{"admin", "health", false},
		{"spaces", "admin_chat_reports", false},
		{"developer", "keys_list", false},
		{"", "x", false},
	} {
		if got := platformAllowed(tc.ns, tc.action); got != tc.ok {
			t.Fatalf("%s.%s: got %v want %v", tc.ns, tc.action, got, tc.ok)
		}
	}
}

func TestPlatformCatalogAndCall(t *testing.T) {
	f := harness(t)
	_ = f.s.K.Actions().Register("spaces", helper.Action{
		Namespace: "spaces", Name: "message_send", Summary: "Send a message",
		Handler: func(_ context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
			var body map[string]any
			_ = json.Unmarshal(req.Body, &body)
			out, _ := json.Marshal(map[string]any{
				"ok": true, "caller": req.Caller.ID.String(), "handle": req.Meta["handle"], "text": body["text"],
			})
			return &api.ActionResponse{Status: 200, Body: out}, nil
		},
	})
	_ = f.s.K.Actions().Register("admin", helper.Action{
		Namespace: "admin", Name: "health", Summary: "Node health",
		Handler: func(context.Context, *api.ActionRequest) (*api.ActionResponse, error) {
			return helper.JSON(map[string]any{"ok": true})
		},
	})
	_ = f.s.K.Actions().Register("spaces", helper.Action{
		Namespace: "spaces", Name: "admin_storage", Summary: "Admin storage",
		Handler: func(context.Context, *api.ActionRequest) (*api.ActionResponse, error) {
			return helper.JSON(map[string]any{"ok": true})
		},
	})

	catalog := f.s.PlatformCatalog(f.ctx)
	if catalog.Base != "/v1/platform" || len(catalog.Namespaces) == 0 {
		t.Fatalf("catalog: %+v", catalog)
	}
	var spaces *PlatformNamespace
	for i := range catalog.Namespaces {
		if catalog.Namespaces[i].Name == "spaces" {
			spaces = &catalog.Namespaces[i]
		}
		if catalog.Namespaces[i].Name == "admin" {
			t.Fatal("admin must not appear in the collection")
		}
	}
	if spaces == nil || len(spaces.Actions) != 1 || spaces.Actions[0].Name != "message_send" {
		t.Fatalf("spaces group should list only the non-admin action: %+v", spaces)
	}

	_, secret := f.key(t, f.personal(t), KeyInput{
		Name: "client",
		Permissions: Permissions{
			Models: LevelRead, Platform: LevelWrite,
		},
	})
	call := func(method network.Method, path, token, body string) *network.Response {
		var handler network.Handler
		for _, r := range f.s.routes() {
			if r.method == method && matchPattern(r.pattern, apiPrefix+path) {
				handler = r.handler
				break
			}
		}
		if handler == nil {
			t.Fatalf("no route for %s %s", method, path)
		}
		req := &network.Request{Method: method, Path: apiPrefix + path, Header: map[string]string{}, Body: []byte(body)}
		if token != "" {
			req.Header["Authorization"] = "Bearer " + token
		}
		if strings.HasPrefix(path, "/platform/") {
			parts := strings.Split(strings.TrimPrefix(path, "/platform/"), "/")
			if len(parts) >= 2 {
				b, _ := json.Marshal(map[string]string{"namespace": parts[0], "action": parts[1]})
				req.Header["x-route-params"] = string(b)
			}
		}
		resp, err := handler(f.ctx, req)
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}

	list := call(network.MethodGet, "/platform", secret, "")
	if list.Status != 200 || !strings.Contains(string(list.Body), `"message_send"`) {
		t.Fatalf("catalog door: %d %s", list.Status, list.Body)
	}
	if denied := call(network.MethodGet, "/platform", "", ""); denied.Status != 401 {
		t.Fatalf("catalog needs a key: %d", denied.Status)
	}

	sent := call(network.MethodPost, "/platform/spaces/message_send", secret, `{"text":"hello"}`)
	if sent.Status != 200 || !strings.Contains(string(sent.Body), `"text":"hello"`) || !strings.Contains(string(sent.Body), `"handle":"ada"`) {
		t.Fatalf("platform call: %d %s", sent.Status, sent.Body)
	}
	if admin := call(network.MethodPost, "/platform/admin/health", secret, `{}`); admin.Status != 404 {
		t.Fatalf("admin stays off the door: %d %s", admin.Status, admin.Body)
	}
	if adminAction := call(network.MethodPost, "/platform/spaces/admin_storage", secret, `{}`); adminAction.Status != 404 {
		t.Fatalf("admin_ actions stay off the door: %d %s", adminAction.Status, adminAction.Body)
	}

	ro, roSecret := f.key(t, f.personal(t), KeyInput{
		Name: "catalog-only", Permissions: Permissions{Platform: LevelRead},
	})
	_ = ro
	if write := call(network.MethodPost, "/platform/spaces/message_send", roSecret, `{}`); write.Status != 403 {
		t.Fatalf("read-only platform key cannot call: %d %s", write.Status, write.Body)
	}
}
