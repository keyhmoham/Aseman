package spaces

import (
	"strings"
	"testing"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/crypto"
	"github.com/tradera/tradera/plugins/actions/spaces/models/proxy"
)

type proxyKeyKernel struct {
	api.Kernel
	key string
}

func (k proxyKeyKernel) Env() map[string]string { return map[string]string{"node_private_key": k.key} }

func TestProxyTokenEncryptionAndMigration(t *testing.T) {
	s, ctx := fileToolHarness(t)
	s.K = proxyKeyKernel{Kernel: s.K, key: strings.Repeat("01", 64)}
	id, _ := identity.New(1)
	p := &proxy.Proxy{}
	p.ID, p.SpaceID, p.Token = id, id, "private-connect-token"
	if err := s.saveProxy(ctx, p, true); err != nil {
		t.Fatal(err)
	}
	var stored proxy.Proxy
	if err := s.R.Get(ctx, "proxies", id, &stored); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(stored.Token, crypto.SecretPrefix) {
		t.Fatal("token stored as plaintext")
	}
	if p.Token != "private-connect-token" {
		t.Fatal("write mutated runtime token")
	}
	if got, err := s.ProxyGet(ctx, id); err != nil || got.Token != p.Token {
		t.Fatalf("unusable proxy token: %v", err)
	}
	if got, err := s.ProxyList(ctx, id); err != nil || len(got) != 1 || got[0].Token != p.Token {
		t.Fatalf("proxy list token unusable: %v", err)
	}
	stored.Token = "legacy-token"
	if err := s.R.Update(ctx, "proxies", id, &stored); err != nil {
		t.Fatal(err)
	}
	if err := s.encryptLegacyProxyTokens(ctx); err != nil {
		t.Fatal(err)
	}
	if err := s.encryptLegacyProxyTokens(ctx); err != nil {
		t.Fatal(err)
	}
	if got, err := s.ProxyGet(ctx, id); err != nil || got.Token != "legacy-token" {
		t.Fatalf("migration failed: %v", err)
	}
	s.K = proxyKeyKernel{Kernel: s.K, key: strings.Repeat("02", 64)}
	if _, err := s.ProxyGet(ctx, id); err == nil {
		t.Fatal("wrong node key was accepted")
	}
	if err := s.encryptLegacyProxyTokens(ctx); err == nil {
		t.Fatal("migration ignored undecryptable credential")
	}
	s.K = proxyKeyKernel{Kernel: s.K}
	if err := s.saveProxy(ctx, p, false); err == nil {
		t.Fatal("plaintext write without encryption key")
	}
}
