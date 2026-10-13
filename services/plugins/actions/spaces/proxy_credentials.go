package spaces

import (
	"context"
	"strings"

	"github.com/tradera/tradera/pkg/crypto"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/spaces/models/proxy"
	database "github.com/tradera/tradera/plugins/adapters/database/ports"
)

func proxyTokenContext(p *proxy.Proxy) string { return "proxies/" + p.ID.String() + "/token" }
func (s *Service) openProxyToken(p *proxy.Proxy) error {
	if !strings.HasPrefix(p.Token, "tradera:secret:") {
		return nil
	}
	token, err := crypto.OpenSecret(p.Token, s.K.Env()["node_private_key"], proxyTokenContext(p))
	if err != nil {
		return errs.New(errs.CodeUnavailable, "proxy credential could not be decrypted")
	}
	p.Token = token
	return nil
}
func (s *Service) saveProxy(ctx context.Context, p *proxy.Proxy, create bool) error {
	stored := *p
	if stored.Token != "" {
		sealed, err := crypto.SealSecret(stored.Token, s.K.Env()["node_private_key"], proxyTokenContext(p))
		if err != nil {
			return errs.New(errs.CodeUnavailable, "proxy credential encryption is unavailable")
		}
		stored.Token = sealed
	}
	if create {
		return s.R.CreateID(ctx, "proxies", stored.ID, &stored)
	}
	return s.R.Update(ctx, "proxies", stored.ID, &stored)
}
func (s *Service) encryptLegacyProxyTokens(ctx context.Context) error {
	var rows []proxy.Proxy
	if err := s.R.List(ctx, "proxies", database.Filter{}, &rows); err != nil {
		return err
	}
	for _, p := range rows {
		if p.Token == "" {
			continue
		}
		if strings.HasPrefix(p.Token, "tradera:secret:") {
			if err := s.openProxyToken(&p); err != nil {
				return err
			}
			continue
		}
		old := p.Token
		sealed, err := crypto.SealSecret(old, s.K.Env()["node_private_key"], proxyTokenContext(&p))
		if err != nil {
			return errs.New(errs.CodeUnavailable, "proxy credential encryption is unavailable")
		}
		p.Token = sealed
		changed, err := s.R.CompareAndSwap(ctx, "proxies", p.ID.String(), map[string]any{"token": old, "updated_at": p.UpdatedAt}, &p)
		if err != nil {
			return err
		}
		if !changed {
			return errs.Conflict("proxy changed during credential migration; retry bootstrap")
		}
	}
	return nil
}
