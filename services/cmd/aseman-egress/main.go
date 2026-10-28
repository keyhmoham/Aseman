// Command aseman-egress is the filtering proxy beside a project computer. It
// runs as a sidecar in the computer's network namespace (so the computer's
// shell and browser reach it at 127.0.0.1:3128 through HTTP(S)_PROXY) and in
// a container of its own (so nothing on the computer can rewrite it). It
// reads the project's egress policy from the node when it starts and every
// half minute after; until it has one, nothing leaves. Cloud metadata and
// link-local addresses are refused in every mode, after DNS resolution too.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/plugins/actions/governance/models/egress"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "version" {
		log.Print("aseman-egress v1")
		return
	}
	p := &proxy{
		policyURL: strings.TrimSpace(os.Getenv("ASEMAN_EGRESS_URL")),
		token:     strings.TrimSpace(os.Getenv("ASEMAN_EGRESS_TOKEN")),
		resolver:  net.DefaultResolver,
		dialer:    &net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second},
	}
	listen := envOr("ASEMAN_EGRESS_LISTEN", "127.0.0.1:3128")
	go p.refresh(context.Background(), 30*time.Second)
	srv := &http.Server{Addr: listen, Handler: p, ReadHeaderTimeout: 30 * time.Second}
	log.Printf("aseman-egress listening on %s", listen)
	log.Fatal(srv.ListenAndServe())
}

func envOr(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

type proxy struct {
	policyURL, token string
	resolver         *net.Resolver
	dialer           *net.Dialer
	client           *http.Client

	mu     sync.RWMutex
	policy *egress.Policy
}

// refresh reads the policy now and every interval after.
func (p *proxy) refresh(ctx context.Context, every time.Duration) {
	for {
		if err := p.load(ctx); err != nil {
			log.Printf("policy not loaded: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(every):
		}
	}
}

func (p *proxy) load(ctx context.Context) error {
	if p.policyURL == "" {
		return errors.New("ASEMAN_EGRESS_URL is not set")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, p.policyURL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+p.token)
	client := p.client
	if client == nil {
		// The node is reached directly, never through this proxy.
		client = &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{Proxy: nil}}
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return errors.New("node answered " + resp.Status)
	}
	var pol egress.Policy
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&pol); err != nil {
		return err
	}
	if !egress.Valid(pol.Mode) {
		return errors.New("unknown mode " + pol.Mode)
	}
	p.mu.Lock()
	p.policy = &pol
	p.mu.Unlock()
	return nil
}

func (p *proxy) current() *egress.Policy {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.policy
}

// allowed decides a host and the addresses it resolves to.
func (p *proxy) allowed(ctx context.Context, hostport string) (string, error) {
	host, port, err := net.SplitHostPort(hostport)
	if err != nil {
		host, port = hostport, "80"
	}
	pol := p.current()
	if pol == nil {
		return "", errors.New("no network policy yet")
	}
	if !pol.AllowsHost(host) {
		return "", errors.New("the project's network policy (" + pol.Mode + ") does not allow " + host)
	}
	ips, err := p.resolver.LookupIPAddr(ctx, host)
	if err != nil {
		return "", err
	}
	for _, ip := range ips {
		if egress.BlockedIP(ip.IP) {
			return "", errors.New(host + " resolves to a link-local or metadata address")
		}
	}
	if len(ips) == 0 {
		return "", errors.New("no address for " + host)
	}
	// Dial the address that was checked, so a second lookup cannot differ.
	return net.JoinHostPort(ips[0].IP.String(), port), nil
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect {
		p.tunnel(w, r)
		return
	}
	if r.URL.Host == "" {
		http.Error(w, "aseman-egress is a proxy", http.StatusBadRequest)
		return
	}
	target, err := p.allowed(r.Context(), hostPort(r.URL.Host, r.URL.Scheme))
	if err != nil {
		refuse(w, r.URL.Host, err)
		return
	}
	out := r.Clone(r.Context())
	out.RequestURI = ""
	for _, h := range []string{"Proxy-Connection", "Proxy-Authorization", "Proxy-Authenticate"} {
		out.Header.Del(h)
	}
	transport := &http.Transport{Proxy: nil, DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
		return p.dialer.DialContext(ctx, network, target)
	}}
	resp, err := transport.RoundTrip(out)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	for k, v := range resp.Header {
		w.Header()[k] = v
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}

func (p *proxy) tunnel(w http.ResponseWriter, r *http.Request) {
	target, err := p.allowed(r.Context(), r.Host)
	if err != nil {
		refuse(w, r.Host, err)
		return
	}
	upstream, err := p.dialer.DialContext(r.Context(), "tcp", target)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		upstream.Close()
		http.Error(w, "tunnel unsupported", http.StatusInternalServerError)
		return
	}
	client, buf, err := hj.Hijack()
	if err != nil {
		upstream.Close()
		return
	}
	_, _ = client.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\n"))
	if buf.Reader.Buffered() > 0 {
		pending := make([]byte, buf.Reader.Buffered())
		_, _ = buf.Read(pending)
		_, _ = upstream.Write(pending)
	}
	go func() {
		_, _ = io.Copy(upstream, client)
		upstream.Close()
	}()
	_, _ = io.Copy(client, upstream)
	client.Close()
}

func refuse(w http.ResponseWriter, host string, err error) {
	log.Printf("refused %s: %v", host, err)
	http.Error(w, "aseman-egress: "+err.Error(), http.StatusForbidden)
}

func hostPort(host, scheme string) string {
	if _, _, err := net.SplitHostPort(host); err == nil {
		return host
	}
	if scheme == "https" {
		return net.JoinHostPort(host, "443")
	}
	return net.JoinHostPort(host, "80")
}
