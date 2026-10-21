// Package cfg provides deterministic extraction of typed port configs from the
// generic map[string]any config maps plugins receive in Init.
package cfg

import (
	"time"

	"github.com/aseman/aseman/plugins/adapters/cache/ports"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/filesystem/ports"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
	"github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

func str(m map[string]any, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

func int64v(m map[string]any, key string) int64 {
	switch v := m[key].(type) {
	case int:
		return int64(v)
	case int64:
		return v
	case float64:
		return int64(v)
	}
	return 0
}

func intv(m map[string]any, key string) int {
	return int(int64v(m, key))
}

func dur(m map[string]any, key string) time.Duration {
	switch v := m[key].(type) {
	case string:
		d, _ := time.ParseDuration(v)
		return d
	case int:
		return time.Duration(v)
	case float64:
		return time.Duration(v)
	}
	return 0
}

func boolv(m map[string]any, key string) bool {
	if v, ok := m[key].(bool); ok {
		return v
	}
	return false
}

func strMap(m map[string]any, key string) map[string]string {
	out := map[string]string{}
	switch raw := m[key].(type) {
	case map[string]any:
		for k, v := range raw {
			if s, ok := v.(string); ok {
				out[k] = s
			}
		}
	case map[string]string:
		for k, v := range raw {
			out[k] = v
		}
	}
	return out
}

// Database extracts a database.Config.
func Database(m map[string]any) database.Config {
	return database.Config{
		DSN:     str(m, "dsn"),
		Options: strMap(m, "options"),
	}
}

// Cache extracts a cache.Config.
func Cache(m map[string]any) cache.Config {
	return cache.Config{
		Addr:     str(m, "addr"),
		Password: str(m, "password"),
		DB:       intv(m, "db"),
		TTL:      dur(m, "ttl"),
		MaxSize:  int64v(m, "max_size"),
		Options:  strMap(m, "options"),
	}
}

// Filesystem extracts a filesystem.Config.
func Filesystem(m map[string]any) filesystem.Config {
	return filesystem.Config{
		BasePath: str(m, "base_path"),
		Bucket:   str(m, "bucket"),
		Region:   str(m, "region"),
		Endpoint: str(m, "endpoint"),
		Options:  strMap(m, "options"),
	}
}

// Network extracts a network.Config.
func Network(m map[string]any) network.Config {
	cfg := network.Config{
		Addr:    str(m, "addr"),
		Path:    str(m, "path"),
		Options: strMap(m, "options"),
	}
	if cert := str(m, "tls_cert"); cert != "" {
		cfg.TLS = &network.TLSConfig{CertFile: cert, KeyFile: str(m, "tls_key")}
	}
	return cfg
}

// VMM extracts a vmm.Config.
func VMM(m map[string]any) vmm.Config {
	return vmm.Config{
		NomadURL:   str(m, "nomad_url"),
		Token:      str(m, "token"),
		Region:     str(m, "region"),
		Datacenter: str(m, "datacenter"),
		Options:    strMap(m, "options"),
	}
}
