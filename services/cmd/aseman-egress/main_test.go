package main

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/aseman/aseman/plugins/actions/governance/models/egress"
)

func TestNothingLeavesWithoutAPolicy(t *testing.T) {
	p := &proxy{resolver: net.DefaultResolver, dialer: &net.Dialer{Timeout: time.Second}}
	if _, err := p.allowed(context.Background(), "example.com:443"); err == nil {
		t.Fatal("without a policy nothing may leave")
	}
}

func TestPolicyFromTheNode(t *testing.T) {
	node := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_ = json.NewEncoder(w).Encode(egress.Policy{Mode: egress.AllowlistOnly, Allow: []string{"127.0.0.1"}})
	}))
	defer node.Close()
	p := &proxy{policyURL: node.URL, token: "tok", resolver: net.DefaultResolver, dialer: &net.Dialer{Timeout: time.Second}, client: node.Client()}
	if err := p.load(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := p.allowed(context.Background(), "127.0.0.1:80"); err != nil {
		t.Fatalf("an allowed host: %v", err)
	}
	if _, err := p.allowed(context.Background(), "example.com:443"); err == nil || !strings.Contains(err.Error(), "allowlist_only") {
		t.Fatalf("a host the policy does not list: %v", err)
	}
	p.token = "wrong"
	if err := p.load(context.Background()); err == nil {
		t.Fatal("a bad token must not load a policy")
	}
}

func TestProxyRefusesAndForwards(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("hello")) }))
	defer upstream.Close()
	p := &proxy{resolver: net.DefaultResolver, dialer: &net.Dialer{Timeout: time.Second}}
	p.policy = &egress.Policy{Mode: egress.AllowlistOnly, Allow: []string{"127.0.0.1"}}
	front := httptest.NewServer(p)
	defer front.Close()
	proxyURL, _ := http.NewRequest(http.MethodGet, front.URL, nil)
	client := &http.Client{Transport: &http.Transport{Proxy: http.ProxyURL(proxyURL.URL)}}
	resp, err := client.Get(upstream.URL)
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("an allowed request: %v %v", resp, err)
	}
	resp.Body.Close()
	resp, err = client.Get("http://169.254.169.254/latest/meta-data")
	if err != nil || resp.StatusCode != http.StatusForbidden {
		t.Fatalf("metadata must be refused: %v %v", resp, err)
	}
	resp.Body.Close()
}
