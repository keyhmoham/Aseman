package tools

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

type keyKernel struct {
	api.Kernel
}

func (keyKernel) Env() map[string]string {
	return map[string]string{"node_private_key": strings.Repeat("ab", 32)}
}

func TestScopeTokenRoundTripAndTamper(t *testing.T) {
	s := &Service{K: keyKernel{}}
	token, err := s.scopeToken(Scope{Bot: "b", Actor: "a", Space: "s", Room: "r"})
	if err != nil {
		t.Fatal(err)
	}
	sc, err := s.openScope(token)
	if err != nil || sc.Bot != "b" || sc.Actor != "a" || sc.Space != "s" || sc.Room != "r" {
		t.Fatalf("scope %+v %v", sc, err)
	}
	body, sig, _ := strings.Cut(token, ".")
	forged, _ := s.scopeToken(Scope{Bot: "b", Actor: "a", Space: "other"})
	forgedBody, _, _ := strings.Cut(forged, ".")
	if _, err := s.openScope(forgedBody + "." + sig); err == nil {
		t.Fatal("a scope signed for another body was accepted")
	}
	if _, err := s.openScope(body + ".00"); err == nil {
		t.Fatal("a bad signature was accepted")
	}
	expired, _ := s.scopeToken(Scope{Bot: "b", Actor: "a", Exp: time.Now().Add(-time.Minute).Unix()})
	if _, err := s.openScope(expired); err == nil {
		t.Fatal("an expired scope was accepted")
	}
}

func TestRuntimeTokenIsPerTool(t *testing.T) {
	s := &Service{K: keyKernel{}}
	a, _ := s.RuntimeToken("k1")
	b, _ := s.RuntimeToken("k2")
	again, _ := s.RuntimeToken("k1")
	if a == b || a != again || a == "" {
		t.Fatal("runtime tokens must be stable per tool and differ between tools")
	}
	if _, err := s.RuntimeToken(""); err == nil {
		t.Fatal("a tool without a runtime key got a credential")
	}
}

func TestHostCallRefusesOtherSpacesAndActions(t *testing.T) {
	s := &Service{K: keyKernel{}}
	sc := Scope{Bot: "b", Actor: "a", Space: "s1"}
	if _, err := s.HostCall(context.Background(), sc, "admin", "plugins_list", nil); err == nil {
		t.Fatal("an action outside the host API was dispatched")
	}
}

func TestToolInputValidation(t *testing.T) {
	cases := []struct {
		name string
		in   toolInput
		ok   bool
	}{
		{"external", toolInput{Name: "x", Backend: backendInput{Mode: "external", URL: "https://mcp.example.com"}}, true},
		{"external without url", toolInput{Name: "x", Backend: backendInput{Mode: "external"}}, false},
		{"managed elpian defaults to dart", toolInput{Name: "x", Backend: backendInput{Mode: "managed", Runtime: "elpian", Source: "Map f(Map a) { return a; }"}}, true},
		{"managed quickjs without a program", toolInput{Name: "x", Backend: backendInput{Mode: "managed", Runtime: "quickjs"}}, false},
		{"installed docker", toolInput{Name: "x", Backend: backendInput{Mode: "installed", Runtime: "docker", Image: "acme/t:1"}}, true},
		{"docker bad path", toolInput{Name: "x", Backend: backendInput{Mode: "managed", Runtime: "docker", Image: "a", Path: "mcp"}}, false},
		{"unknown runtime", toolInput{Name: "x", Backend: backendInput{Mode: "managed", Runtime: "python", Source: "x"}}, false},
		{"static frontend", toolInput{Name: "x", Backend: backendInput{Mode: "external", URL: "https://a"}, Frontend: frontendInput{Mode: "static", Runtime: "quickjs", Source: "askHost('render','{}')"}}, true},
		{"unknown frontend mode", toolInput{Name: "x", Backend: backendInput{Mode: "external", URL: "https://a"}, Frontend: frontendInput{Mode: "html"}}, false},
		{"no name", toolInput{Backend: backendInput{Mode: "external", URL: "https://a"}}, false},
	}
	for _, c := range cases {
		in := c.in
		err := in.validate()
		if (err == nil) != c.ok {
			t.Fatalf("%s: err=%v", c.name, err)
		}
	}
	in := toolInput{Name: "x", Backend: backendInput{Mode: "managed", Runtime: "elpian", Source: "x"}}
	_ = in.validate()
	if in.Backend.Language != "dart" {
		t.Fatal("an Elpian program defaults to Dart")
	}
	d := toolInput{Name: "x", Backend: backendInput{Mode: "installed", Runtime: "docker", Image: "a"}}
	_ = d.validate()
	if d.Backend.Port != 8080 || d.Backend.Path != "/mcp" {
		t.Fatalf("docker defaults %d %s", d.Backend.Port, d.Backend.Path)
	}
}

func TestToolResultValue(t *testing.T) {
	v, err := vmm.ToolResultValue(`{"content":[{"type":"text","text":"{\"t\":21}"}]}`)
	if err != nil || v.(map[string]any)["t"] != float64(21) {
		t.Fatalf("%v %v", v, err)
	}
	v, _ = vmm.ToolResultValue(`{"content":[],"structuredContent":{"ok":true}}`)
	if v.(map[string]any)["ok"] != true {
		t.Fatalf("%v", v)
	}
	if _, err := vmm.ToolResultValue(`{"content":[{"type":"text","text":"boom"}],"isError":true}`); err == nil {
		t.Fatal("an error result was data")
	}
}

func TestInstallPortIsStable(t *testing.T) {
	p := installPort("0000000000000001abcdefabcdefabcd")
	if p != installPort("0000000000000001abcdefabcdefabcd") || p < 20000 || p >= 40000 {
		t.Fatalf("port %d", p)
	}
}

func TestFrontendInputModes(t *testing.T) {
	if err := (&frontendInput{Mode: "static", Runtime: "quickjs", Source: "1"}).validate(); err != nil {
		t.Fatalf("static: %v", err)
	}
	if err := (&frontendInput{Mode: ""}).validate(); err != nil {
		t.Fatalf("none: %v", err)
	}
	if err := (&frontendInput{Mode: "html"}).validate(); err == nil {
		t.Fatal("unknown frontend mode must be rejected")
	}
}
