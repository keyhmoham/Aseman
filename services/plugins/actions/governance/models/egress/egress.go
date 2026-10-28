// Package egress decides where a project computer may connect. The node's
// gate and the computer's filtering proxy (cmd/aseman-egress) share it, so a
// host is allowed or refused the same way on both sides.
package egress

import (
	"net"
	"strings"
)

// Modes.
const (
	AllowAll      = "allow_all"
	DefaultsPlus  = "defaults_plus_allowlist"
	AllowlistOnly = "allowlist_only"
	DenyAll       = "deny_all"
)

// Policy is what the proxy is given.
type Policy struct {
	Mode  string   `json:"mode"`
	Allow []string `json:"allow"`
	// Always are hosts the computer reaches whatever the mode: the node itself
	// and the services it runs for the computer.
	Always []string `json:"always,omitempty"`
}

// Defaults are the hosts a computer building software needs: package
// registries, source hosting and the operating system's archives.
var Defaults = []string{
	"registry.npmjs.org", "registry.yarnpkg.com", "*.npmjs.org",
	"pypi.org", "files.pythonhosted.org",
	"proxy.golang.org", "sum.golang.org", "storage.googleapis.com",
	"crates.io", "static.crates.io", "index.crates.io",
	"rubygems.org", "repo.maven.apache.org", "repo1.maven.org",
	"github.com", "*.github.com", "*.githubusercontent.com", "codeload.github.com",
	"gitlab.com", "bitbucket.org",
	"deb.debian.org", "security.debian.org", "archive.ubuntu.com", "security.ubuntu.com",
	"dl-cdn.alpinelinux.org", "cdn.jsdelivr.net", "unpkg.com", "registry-1.docker.io",
}

// Metadata are cloud metadata endpoints, refused in every mode.
var Metadata = []string{"169.254.169.254", "metadata.google.internal", "metadata.azure.com", "100.100.100.200", "fd00:ec2::254", "metadata"}

// Valid reports a known mode.
func Valid(mode string) bool {
	switch mode {
	case AllowAll, DefaultsPlus, AllowlistOnly, DenyAll:
		return true
	}
	return false
}

// AllowsHost decides a host name (before it is resolved).
func (p Policy) AllowsHost(host string) bool {
	host = normalize(host)
	if host == "" {
		return false
	}
	for _, m := range Metadata {
		if host == m {
			return false
		}
	}
	if ip := net.ParseIP(host); ip != nil && BlockedIP(ip) {
		return false
	}
	if matchAny(host, p.Always) {
		return true
	}
	switch p.Mode {
	case AllowAll:
		return true
	case DefaultsPlus:
		return matchAny(host, Defaults) || matchAny(host, p.Allow)
	case AllowlistOnly:
		return matchAny(host, p.Allow)
	}
	return false
}

// BlockedIP refuses link-local addresses (cloud metadata lives there) and the
// unspecified address, whatever the mode. Private ranges stay reachable: the
// node and the services it runs for the computer are on them.
func BlockedIP(ip net.IP) bool {
	return ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() || ip.Equal(net.ParseIP("100.100.100.200"))
}

// ValidPattern reports a host pattern the allowlist accepts: a host name, an
// IP, or "*." followed by a domain.
func ValidPattern(p string) bool {
	p = normalize(p)
	if p == "" || strings.ContainsAny(p, " /:@") {
		return net.ParseIP(p) != nil
	}
	if strings.HasPrefix(p, "*.") {
		p = p[2:]
	}
	return p != "" && !strings.Contains(p, "*")
}

func matchAny(host string, patterns []string) bool {
	for _, raw := range patterns {
		p := normalize(raw)
		switch {
		case p == "":
		case p == host:
			return true
		case strings.HasPrefix(p, "*.") && strings.HasSuffix(host, p[1:]):
			return true
		}
	}
	return false
}

func normalize(h string) string {
	h = strings.ToLower(strings.TrimSpace(h))
	h = strings.TrimSuffix(h, ".")
	if strings.HasPrefix(h, "[") && strings.HasSuffix(h, "]") {
		h = h[1 : len(h)-1]
	}
	return h
}
