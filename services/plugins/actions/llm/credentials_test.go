package llm

import (
	"strings"
	"testing"

	"github.com/aseman/aseman/pkg/crypto"
	models "github.com/aseman/aseman/plugins/actions/llm/models"
)

const testNodeKey = "01010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101"

func TestProviderKeysEncryptedAndMigrated(t *testing.T) {
	s, ctx, owner := harness(t)
	p, err := s.Set(ctx, owner, ProviderInput{Kind: models.KindOpenAI, APIKey: "sk-private-key"})
	if err != nil {
		t.Fatal(err)
	}
	var stored models.Provider
	if err := s.R.Get(ctx, model, p.ID, &stored); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(stored.APIKey, crypto.SecretPrefix) || strings.Contains(stored.APIKey, "sk-private-key") {
		t.Fatal("key stored in plaintext")
	}
	if p.APIKey != "sk-private-key" {
		t.Fatal("caller received encrypted runtime key")
	}
	// Inject a legacy plaintext row and run the bootstrap migration twice.
	stored.APIKey = "sk-legacy-key"
	if err := s.R.Update(ctx, model, stored.ID, &stored); err != nil {
		t.Fatal(err)
	}
	if err := s.encryptLegacyKeys(ctx); err != nil {
		t.Fatal(err)
	}
	if err := s.R.Get(ctx, model, p.ID, &stored); err != nil {
		t.Fatal(err)
	}
	ciphertext := stored.APIKey
	if !strings.HasPrefix(ciphertext, crypto.SecretPrefix) {
		t.Fatal("legacy key not migrated")
	}
	if err := s.encryptLegacyKeys(ctx); err != nil {
		t.Fatal(err)
	}
	if err := s.R.Get(ctx, model, p.ID, &stored); err != nil {
		t.Fatal(err)
	}
	if stored.APIKey != ciphertext {
		t.Fatal("migration is not idempotent")
	}
	if got, err := s.Get(ctx, p.ID); err != nil || got.APIKey != "sk-legacy-key" {
		t.Fatalf("migrated key unusable: %v", err)
	}
	if _, err := s.Set(ctx, owner, ProviderInput{ID: p.ID.String(), Kind: models.KindOpenAI, Name: "renamed"}); err != nil {
		t.Fatal(err)
	}
	if got, err := s.Get(ctx, p.ID); err != nil || got.APIKey != "sk-legacy-key" {
		t.Fatal("blank update lost key")
	}
	// An encrypted key moved to another record cannot be decrypted.
	other, err := s.Set(ctx, owner, ProviderInput{Kind: models.KindOpenAI, APIKey: "another-key"})
	if err != nil {
		t.Fatal(err)
	}
	other.APIKey = ciphertext
	if err := s.R.Update(ctx, model, other.ID, other); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Get(ctx, other.ID); err == nil {
		t.Fatal("ciphertext accepted for another provider")
	}
}

func TestProviderEncryptionFailsClosed(t *testing.T) {
	s, ctx, owner := harness(t)
	s.K = noKeyKernel{s.K}
	if _, err := s.Set(ctx, owner, ProviderInput{Kind: models.KindOpenAI, APIKey: "secret"}); err == nil {
		t.Fatal("plaintext write allowed without key")
	}
}

type noKeyKernel struct{ Kernel }

func (noKeyKernel) Env() map[string]string { return map[string]string{} }
