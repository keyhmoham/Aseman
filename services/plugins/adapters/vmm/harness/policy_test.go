package harness

import (
	"context"
	"encoding/json"
	"net/url"
	"testing"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/actionschema"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// catalogRouter lists a fixed set of actions.
type catalogRouter struct {
	api.ActionRouter
	actions map[string][]api.ActionMeta
}

func (r catalogRouter) Namespaces() []string {
	out := []string{}
	for ns := range r.actions {
		out = append(out, ns)
	}
	return out
}

func (r catalogRouter) List(ns string) []api.ActionMeta { return r.actions[ns] }

func TestTheCatalogListsOnlyWhatTheSessionMayCall(t *testing.T) {
	router := catalogRouter{actions: map[string][]api.ActionMeta{
		"spaces":  {{Namespace: "spaces", Name: "room_create", Summary: "Create a room"}, {Namespace: "spaces", Name: "space_create", Summary: "Create a space"}, {Namespace: "spaces", Name: "admin_storage", Summary: "Storage"}},
		"themes":  {{Namespace: "themes", Name: "apply", Summary: "Apply a theme"}},
		"admin":   {{Namespace: "admin", Name: "health", Summary: "Node health"}},
		"finance": {{Namespace: "finance", Name: "transfer", Summary: "Move money"}, {Namespace: "finance", Name: "wallet_get", Summary: "Read the wallet"}},
	}}
	names := func(s *session, q string) map[string]bool {
		out := map[string]bool{}
		for _, e := range catalog(router, s.allows, q, "", 40) {
			out[e.Namespace+"."+e.Name] = true
		}
		return out
	}
	room := &session{spaceID: "s"}
	got := names(room, "")
	if !got["spaces.room_create"] || got["spaces.space_create"] || got["themes.apply"] || got["admin.health"] || got["finance.wallet_get"] || got["spaces.admin_storage"] {
		t.Fatalf("room catalog = %v", got)
	}
	person := &session{personal: true, account: identity.MustParse("00000000000000010000000000000001")}
	got = names(person, "")
	if !got["themes.apply"] || !got["spaces.space_create"] || !got["finance.wallet_get"] || got["finance.transfer"] || got["admin.health"] {
		t.Fatalf("personal catalog = %v", got)
	}
	if got := names(person, "theme"); len(got) != 1 || !got["themes.apply"] {
		t.Fatalf("search by words = %v", got)
	}
}

func TestAgentsCannotCallBeyondThePolicyThroughTheGateway(t *testing.T) {
	a, _, router := newTestAdapter(t)
	roomSession(a, "tok", "0000000000000001000000000000a001", "bot-1", false)
	for _, call := range []string{
		`{"namespace":"finance","action":"transfer","body":{}}`,
		`{"namespace":"spaces","action":"space_create","body":{}}`,
		`{"namespace":"spaces","action":"message_send","body":{"space":"0000000000000001000000000000b001"}}`,
	} {
		out := post(t, a.serveCall, "tok", call)
		if out["_status"] != float64(403) {
			t.Fatalf("%s = %v", call, out)
		}
	}
	if len(router.calls) != 0 {
		t.Fatalf("refused calls were dispatched: %+v", router.calls)
	}
}

func TestTimelineReadsUseTheTurnsOwnSpace(t *testing.T) {
	a, _, _ := newTestAdapter(t)
	var asked []string
	a.platform = fakePlatform{timeline: func(spaceID string, query []byte) ([]byte, error) {
		asked = append(asked, spaceID)
		return []byte(`{"items":[]}`), nil
	}}
	roomSession(a, "tok", "0000000000000001000000000000a001", "bot-1", false)
	// A space named in the query is ignored: the session's space is used.
	if out := post(t, a.serveTimelineSearch, "tok", `{"query":"x","space":"0000000000000001000000000000b001"}`); out["_status"] != float64(200) {
		t.Fatalf("search = %v", out)
	}
	if len(asked) != 1 || asked[0] != "0000000000000001000000000000a001" {
		t.Fatalf("timeline asked for %v", asked)
	}
	roomSession(a, "fresh", "0000000000000001000000000000a001", "bot-1", true)
	if out := post(t, a.serveTimelineSearch, "fresh", `{}`); out["_status"] != float64(403) {
		t.Fatalf("no-memory timeline = %v", out)
	}
	personSession(a, "me", identity.MustParse("00000000000000010000000000000001"))
	if out := post(t, a.serveTimelineSearch, "me", `{}`); out["_status"] != float64(400) {
		t.Fatalf("personal timeline = %v", out)
	}
	resp, _ := a.serveCatalog(context.Background(), &network.Request{Header: map[string]string{"Authorization": "Bearer nope"}, Query: url.Values{}})
	var body map[string]any
	_ = json.Unmarshal(resp.Body, &body)
	if resp.Status != 401 {
		t.Fatalf("catalog without a turn = %d %v", resp.Status, body)
	}
}

// The catalog's input schemas are read from the actions' source: regenerate
// them (go generate ./plugins/adapters/vmm/harness) when an action's body changes.
func TestActionSchemasAreCurrent(t *testing.T) {
	schemas, err := actionschema.Generate("../../../..", "plugins/actions")
	if err != nil {
		t.Fatal(err)
	}
	raw, err := actionschema.Encode(schemas)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != string(actionSchemasJSON) {
		t.Fatal("action_schemas.json is stale: run go generate ./plugins/adapters/vmm/harness")
	}
	if s := actionSchemas()["routines.create"]; s == nil || s["properties"].(map[string]any)["task"] == nil {
		t.Fatalf("routines.create: %v", s)
	}
}
