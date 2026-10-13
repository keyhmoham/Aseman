package kernel

import (
	"sync"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/adapters/network/ports"
)

type networkBinding struct{ bind, unbind func(network.Network) error }

// BindRoutes installs plugin-owned routes on existing and future network providers.
func (k *Kernel) BindRoutes(owner string, bind, unbind func(network.Network) error) (func(), error) {
	k.routeMu.Lock()
	defer k.routeMu.Unlock()
	if k.routeBindings == nil {
		k.routeBindings = make(map[string]networkBinding)
	}
	if _, exists := k.routeBindings[owner]; exists {
		return nil, errs.Conflict("network routes already owned by " + owner)
	}
	var bound []network.Network
	for _, e := range k.reg.List() {
		if n, ok := e.Plugin.(network.Network); ok {
			if err := bind(n); err != nil {
				if unbind != nil {
					for _, n := range bound {
						_ = unbind(n)
					}
				}
				return nil, err
			}
			bound = append(bound, n)
		}
	}
	k.routeBindings[owner] = networkBinding{bind: bind, unbind: unbind}
	var once sync.Once
	return func() {
		once.Do(func() {
			k.routeMu.Lock()
			defer k.routeMu.Unlock()
			delete(k.routeBindings, owner)
			if unbind != nil {
				for _, e := range k.reg.List() {
					if n, ok := e.Plugin.(network.Network); ok {
						_ = unbind(n)
					}
				}
			}
		})
	}, nil
}
func (k *Kernel) bindPluginRoutes(n network.Network) error {
	k.routeMu.Lock()
	defer k.routeMu.Unlock()
	for _, binding := range k.routeBindings {
		if err := binding.bind(n); err != nil {
			return err
		}
	}
	return nil
}

func (k *Kernel) BindProxy(owner string, handler api.ProxyHandler) (func(), error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.proxyOwner != "" {
		return nil, errs.Conflict("remote action transport already owned by " + k.proxyOwner)
	}
	k.proxyOwner, k.proxy = owner, handler
	var once sync.Once
	return func() {
		once.Do(func() {
			k.mu.Lock()
			defer k.mu.Unlock()
			if k.proxyOwner == owner {
				k.proxyOwner = ""
				k.proxy = nil
			}
		})
	}, nil
}
