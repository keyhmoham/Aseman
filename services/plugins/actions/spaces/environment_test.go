package spaces

import (
	"encoding/json"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"reflect"
	"strings"
	"testing"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/pkg/logger"
	"github.com/aseman/aseman/plugins/actions/routines"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func TestSpaceToolContractsMatchPromptCatalog(t *testing.T) {
	s, ctx := messageToolHarness(t)
	ctx = helper.WithInternalAccess(ctx)
	spaceID := idFromHex(t, "00000000000000010000000000000001")
	s.Routines = routine.NewService(s.K, s.R, logger.Global())
	// The catalog of a node with OpenCode off (the default), then on.
	for _, openCode := range []bool{false, true} {
		if _, err := s.SetOpenCode(ctx, openCode); err != nil {
			t.Fatal(err)
		}
		tools, err := s.SpaceTools(ctx, spaceID, spaceID)
		if err != nil {
			t.Fatal(err)
		}
		actual := map[string]vmm.Tool{}
		for _, tool := range tools {
			if _, ok := actual[tool.Name]; ok {
				t.Fatalf("duplicate tool %s", tool.Name)
			}
			actual[tool.Name] = tool
		}
		for _, contract := range vmm.BuiltinsFor(openCode) {
			if strings.HasPrefix(contract.Name, "memory_") {
				continue
			} // manager is intentionally absent in this fixture
			if gate.ToolOwner(contract.Name) != "" {
				if _, ok := actual[contract.Name]; ok {
					t.Fatalf("%s is offered though its namespace is not loaded", contract.Name)
				}
				continue
			}
			tool, ok := actual[contract.Name]
			if !ok || !reflect.DeepEqual(tool.Parameters, contract.Parameters) || tool.Usage != contract.Usage {
				t.Fatalf("schema drift for %s (opencode %v)", contract.Name, openCode)
			}
		}
		if _, ok := actual["memory_set"]; ok {
			t.Fatal("advertised unwired memory manager")
		}
	}
}

func TestProxyToolsScopeAndHideCredentials(t *testing.T) {
	s, ctx := messageToolHarness(t)
	ctx = helper.WithInternalAccess(ctx)
	workspace := idFromHex(t, "00000000000000010000000000000001")
	other := idFromHex(t, "00000000000000010000000000000002")
	id := idFromHex(t, "00000000000000010000000000000003")
	record := proxy.Proxy{Entity: entity.Entity{ID: id}, SpaceID: workspace, Port: 8080, Title: "preview", Token: "secret-token", TargetURL: "secret-upstream", Path: "/v1/proxy/preview/"}
	if err := s.R.CreateID(ctx, "proxies", id, &record); err != nil {
		t.Fatal(err)
	}
	args := `{"id":"` + id.String() + `"}`
	for _, name := range []string{"proxy_list", "proxy_get"} {
		result, err := s.ToolDispatch(ctx, workspace.String(), "worker", name, args)
		if err != nil {
			t.Fatal(err)
		}
		if !json.Valid([]byte(result)) || !strings.Contains(result, "preview") || strings.Contains(result, "secret-") {
			t.Fatalf("bad public representation %s", result)
		}
	}
	for _, name := range []string{"proxy_get", "proxy_delete"} {
		if _, err := s.ToolDispatch(ctx, other.String(), "worker", name, args); err == nil {
			t.Fatalf("%s crossed workspace boundary", name)
		}
	}
	if _, err := s.ProxyGet(ctx, id); err != nil {
		t.Fatal("cross-workspace delete removed proxy")
	}
	if _, err := s.ToolDispatch(ctx, workspace.String(), "worker", "proxy_delete", args); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ProxyGet(ctx, id); err == nil {
		t.Fatal("proxy was not deleted")
	}
}
