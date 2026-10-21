// Package mcp implements remote MCP protocol transport, including SSE responses.
package mcp

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type Client struct{ HTTP *http.Client }

func New(allowPrivate bool) *Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		host, port, e := net.SplitHostPort(address)
		if e != nil {
			return nil, e
		}
		ips, e := net.DefaultResolver.LookupIPAddr(ctx, host)
		if e != nil {
			return nil, e
		}
		for _, a := range ips {
			if !allowPrivate && (a.IP.IsPrivate() || a.IP.IsLoopback() || a.IP.IsLinkLocalUnicast() || a.IP.IsLinkLocalMulticast() || a.IP.IsUnspecified() || a.IP.IsMulticast()) {
				continue
			}
			conn, e := (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, network, net.JoinHostPort(a.IP.String(), port))
			if e == nil {
				return conn, nil
			}
		}
		return nil, errors.New("MCP address is not reachable under the configured network policy")
	}
	return &Client{HTTP: &http.Client{Transport: transport, Timeout: 90 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}
func ValidURL(raw string) error {
	u, e := url.Parse(raw)
	if e != nil || u.Host == "" || u.User != nil || (u.Scheme != "https" && u.Scheme != "http") {
		return errors.New("an http(s) MCP address without URL credentials is required")
	}
	return nil
}
func (c *Client) FetchJSON(ctx context.Context, target string, headers map[string]string, method string, payload any) (map[string]any, http.Header, error) {
	if e := ValidURL(target); e != nil {
		return nil, nil, e
	}
	var body io.Reader
	if payload != nil {
		b, e := json.Marshal(payload)
		if e != nil {
			return nil, nil, e
		}
		body = bytes.NewReader(b)
	}
	req, e := http.NewRequestWithContext(ctx, method, target, body)
	if e != nil {
		return nil, nil, e
	}
	req.Header.Set("Accept", "application/json, text/event-stream")
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	res, e := c.HTTP.Do(req)
	if e != nil {
		return nil, nil, e
	}
	defer res.Body.Close()
	b, e := io.ReadAll(io.LimitReader(res.Body, 4<<20))
	if e != nil {
		return nil, nil, e
	}
	if res.StatusCode >= 300 {
		return nil, res.Header, fmt.Errorf("MCP provider returned HTTP %d", res.StatusCode)
	}
	var out map[string]any
	if len(bytes.TrimSpace(b)) == 0 {
		return map[string]any{}, res.Header, nil
	}
	if json.Unmarshal(b, &out) == nil {
		return out, res.Header, nil
	}
	scan := bufio.NewScanner(bytes.NewReader(b))
	scan.Buffer(make([]byte, 65536), 4<<20)
	for scan.Scan() {
		line := strings.TrimSpace(scan.Text())
		if strings.HasPrefix(line, "data:") {
			var row map[string]any
			if json.Unmarshal([]byte(strings.TrimSpace(strings.TrimPrefix(line, "data:"))), &row) == nil {
				if _, ok := row["result"]; ok {
					out = row
				}
				if _, ok := row["error"]; ok {
					out = row
				}
			}
		}
	}
	if out == nil {
		return nil, res.Header, errors.New("MCP provider returned no JSON-RPC result")
	}
	return out, res.Header, nil
}
func (c *Client) RPC(ctx context.Context, target string, headers map[string]string, method string, params any) (map[string]any, error) {
	out, _, e := c.FetchJSON(ctx, target, headers, http.MethodPost, map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	if e != nil {
		return nil, e
	}
	if remote, ok := out["error"].(map[string]any); ok {
		return nil, fmt.Errorf("MCP error: %v", remote["message"])
	}
	result, _ := out["result"].(map[string]any)
	if result == nil {
		return nil, errors.New("MCP result must be an object")
	}
	return result, nil
}
func (c *Client) Session(ctx context.Context, target string, headers map[string]string) (map[string]string, error) {
	copy := map[string]string{}
	for k, v := range headers {
		copy[k] = v
	}
	out, h, e := c.FetchJSON(ctx, target, copy, http.MethodPost, map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{}, "clientInfo": map[string]any{"name": "aseman", "version": "1.0.0"}}})
	if e != nil {
		return nil, e
	}
	if out["error"] != nil {
		return nil, errors.New("MCP initialization was refused")
	}
	if id := h.Get("Mcp-Session-Id"); id != "" {
		copy["Mcp-Session-Id"] = id
	}
	copy["MCP-Protocol-Version"] = "2025-06-18"
	_, _, e = c.FetchJSON(ctx, target, copy, http.MethodPost, map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"})
	return copy, e
}
