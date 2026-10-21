package auth

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/crypto"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/support/metasvc"
	"github.com/aseman/aseman/plugins/actions/support/models/metadata"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
)

// oauthLink tracks identity providers an account signs in with. It lives in
// the account's private metadata under "auth" (never a public path), so the
// node can tell an account whose only credential is a provider from one with a
// password its owner chose, and allow linking multiple providers (Google, Apple, etc.).
type oauthLink struct {
	Provider  string            `json:"provider,omitempty"`
	Sub       string            `json:"sub,omitempty"`
	Providers map[string]string `json:"providers,omitempty"`
	// Password reports that the owner has since set a password of their own.
	Password bool `json:"password,omitempty"`
}

// HasProvider checks if a provider name is linked.
func (l *oauthLink) HasProvider(provider string) bool {
	if l.Providers != nil {
		if _, ok := l.Providers[provider]; ok {
			return true
		}
	}
	return l.Provider == provider
}

// Matches checks if the given provider and sub match an existing link.
func (l *oauthLink) Matches(provider, sub string) bool {
	if l.Providers != nil {
		if s, ok := l.Providers[provider]; ok && s == sub {
			return true
		}
	}
	return l.Provider == provider && l.Sub == sub
}

// Link registers a provider and sub on this account.
func (l *oauthLink) Link(provider, sub string) {
	if l.Providers == nil {
		l.Providers = make(map[string]string)
	}
	if l.Provider != "" && l.Sub != "" {
		l.Providers[l.Provider] = l.Sub
	}
	l.Providers[provider] = sub
	l.Provider = provider
	l.Sub = sub
}

func (s *Service) loadOAuthLink(ctx context.Context, id identity.ID) (oauthLink, bool) {
	m := metasvc.Service{K: s.K, R: s.R}
	rec, err := m.Get(ctx, id)
	if err != nil || rec == nil {
		return oauthLink{}, false
	}
	t, _ := rec.Tree["auth"].(map[string]any)
	if t == nil {
		return oauthLink{}, false
	}
	provider, _ := t["provider"].(string)
	sub, _ := t["sub"].(string)
	password, _ := t["password"].(bool)

	providers := make(map[string]string)
	if rawProviders, ok := t["providers"].(map[string]any); ok {
		for k, v := range rawProviders {
			if vs, ok := v.(string); ok && vs != "" {
				providers[k] = vs
			}
		}
	} else if rawProvidersTyped, ok := t["providers"].(map[string]string); ok {
		for k, v := range rawProvidersTyped {
			if v != "" {
				providers[k] = v
			}
		}
	}
	if provider != "" && sub != "" {
		providers[provider] = sub
	}

	if len(providers) == 0 && provider == "" {
		return oauthLink{}, false
	}
	return oauthLink{
		Provider:  provider,
		Sub:       sub,
		Providers: providers,
		Password:  password,
	}, true
}

func (s *Service) saveOAuthLink(ctx context.Context, id identity.ID, l oauthLink) error {
	m := metasvc.Service{K: s.K, R: s.R}
	rec, err := m.Get(ctx, id)
	if err != nil {
		return err
	}
	rawProviders := make(map[string]any)
	for k, v := range l.Providers {
		rawProviders[k] = v
	}
	if l.Provider != "" && l.Sub != "" {
		rawProviders[l.Provider] = l.Sub
	}
	rec.Tree["auth"] = map[string]any{
		"provider":  l.Provider,
		"sub":       l.Sub,
		"providers": rawProviders,
		"password":  l.Password,
	}
	return m.ReplaceTree(ctx, id, rec.Tree)
}

// recoverKey decrypts an account's identity key with the node's recovery copy.
func (s *Service) recoverKey(a *account.Account) (string, error) {
	nodeKey := s.K.Env()["node_private_key"]
	if a.RecoveryKeyEnc == "" || nodeKey == "" {
		return "", errs.New(errs.CodeUnavailable, "account identity recovery is not initialized")
	}
	priv, err := crypto.DecryptPrivateKey(a.RecoveryKeyEnc, nodeKey)
	if err != nil {
		return "", errs.New(errs.CodeUnavailable, "account identity recovery failed")
	}
	return priv, nil
}

// findAccountByOAuth searches for an account linked to the given OAuth provider and sub.
func (s *Service) findAccountByOAuth(ctx context.Context, provider, sub string) (*account.Account, bool) {
	if provider == "" || sub == "" {
		return nil, false
	}
	var metaList []metadata.Record
	if err := s.R.List(ctx, "metadatas", database.Filter{}, &metaList); err != nil {
		return nil, false
	}
	for _, rec := range metaList {
		t, _ := rec.Tree["auth"].(map[string]any)
		if t == nil {
			continue
		}
		link := oauthLink{
			Provider:  toString(t["provider"]),
			Sub:       toString(t["sub"]),
			Providers: make(map[string]string),
		}
		if rawProviders, ok := t["providers"].(map[string]any); ok {
			for k, v := range rawProviders {
				if vs := toString(v); vs != "" {
					link.Providers[k] = vs
				}
			}
		} else if rawProvidersTyped, ok := t["providers"].(map[string]string); ok {
			for k, v := range rawProvidersTyped {
				if v != "" {
					link.Providers[k] = v
				}
			}
		}
		if link.Provider != "" && link.Sub != "" {
			link.Providers[link.Provider] = link.Sub
		}
		if link.Matches(provider, sub) {
			ownerID, err := identity.Parse(rec.Owner)
			if err != nil {
				continue
			}
			var acc account.Account
			if err := s.R.Get(ctx, "accounts", ownerID, &acc); err == nil {
				return &acc, true
			}
		}
	}
	return nil, false
}

func toString(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}
