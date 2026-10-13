// Package openviking reaches the node's self-hosted OpenViking server, which
// keeps the agents' memory (https://openviking.ai). The deep agents runtime
// does most of the work there; the node only reads and edits the agents'
// notes for people and re-indexes memory when the admin changes the embedding
// model.
//
// The server runs in trusted mode: every request carries the root key and
// names the account and user it acts as. A space is an account, an agent a
// user of it; the identifiers below must match the runtime's
// (tradera_agents/memory.py).
package openviking

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
)

// Environment the node reads OpenViking's address and root key from.
const (
	EnvURL = "TRADERA_OPENVIKING_URL"
	EnvKey = "TRADERA_OPENVIKING_API_KEY"
)

// SpaceNotes is the space's shared notes, in the space's account.
const SpaceNotes = "viking://resources/space/notes.md"

// AgentNotes is an agent's own notes, in the space's account.
func AgentNotes(user string) string { return "viking://user/" + user + "/memories/notes.md" }

var nonID = regexp.MustCompile(`[^a-zA-Z0-9_.-]+`)

// id is an OpenViking identifier made from a platform id, as the runtime makes it.
func id(prefix, value string) string {
	clean := strings.Trim(nonID.ReplaceAllString(value, "-"), "-.")
	if clean == "" {
		clean = "x"
	}
	if len(clean) > 64 {
		sum := sha256.Sum256([]byte(value))
		clean = clean[:48] + "-" + hex.EncodeToString(sum[:])[:12]
	}
	return prefix + clean
}

// SpaceAccount is the account of a space.
func SpaceAccount(spaceID string) string {
	if spaceID == "" {
		spaceID = "default"
	}
	return id("space-", spaceID)
}

// AgentUser is the user of an agent (by its bot id).
func AgentUser(botID string) string { return id("agent-", botID) }

// Client talks to one OpenViking server.
type Client struct {
	URL  string
	Key  string
	HTTP *http.Client
}

// FromEnv is the node's OpenViking, or nil when it has none.
func FromEnv() *Client {
	u := strings.TrimRight(strings.TrimSpace(os.Getenv(EnvURL)), "/")
	if u == "" {
		return nil
	}
	return &Client{URL: u, Key: strings.TrimSpace(os.Getenv(EnvKey)), HTTP: &http.Client{Timeout: 30 * time.Second}}
}

// Error is an error OpenViking answered with.
type Error struct {
	Status  int
	Code    string
	Message string
}

func (e *Error) Error() string {
	return fmt.Sprintf("openviking: %s (%d): %s", e.Code, e.Status, e.Message)
}

// NotFound reports whether err says there is no such file.
func NotFound(err error) bool {
	e, ok := err.(*Error)
	return ok && (e.Code == "NOT_FOUND" || e.Status == http.StatusNotFound)
}

// Busy reports whether err says the target is locked for now (being processed).
func Busy(err error) bool {
	e, ok := err.(*Error)
	return ok && (e.Code == "CONFLICT" || e.Code == "RESOURCE_BUSY" || e.Status == http.StatusConflict)
}

// as says whom a request acts as.
type as struct {
	account, user, role string
}

func (c *Client) do(ctx context.Context, who as, method, path string, query url.Values, body any) (json.RawMessage, error) {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(raw)
	}
	target := c.URL + path
	if len(query) > 0 {
		target += "?" + query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, target, reader)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.Key != "" {
		req.Header.Set("X-API-Key", c.Key)
	}
	if who.account != "" {
		req.Header.Set("X-OpenViking-Account", who.account)
	}
	if who.user != "" {
		req.Header.Set("X-OpenViking-User", who.user)
	}
	if who.role != "" {
		req.Header.Set("X-OpenViking-Role", who.role)
	}
	client := c.HTTP
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	var out struct {
		Status string          `json:"status"`
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
		Detail any `json:"detail"`
	}
	if json.Unmarshal(data, &out) != nil {
		if resp.StatusCode >= 300 {
			return nil, &Error{Status: resp.StatusCode, Code: "HTTP", Message: strings.TrimSpace(string(data))}
		}
		return nil, &Error{Status: resp.StatusCode, Code: "BAD_RESPONSE", Message: "not JSON"}
	}
	if out.Status == "error" && out.Error != nil {
		return nil, &Error{Status: resp.StatusCode, Code: out.Error.Code, Message: out.Error.Message}
	}
	if resp.StatusCode >= 300 {
		return nil, &Error{Status: resp.StatusCode, Code: "HTTP", Message: fmt.Sprint(out.Detail)}
	}
	return out.Result, nil
}

// Read returns a file's text.
func (c *Client) Read(ctx context.Context, account, user, uri string) (string, error) {
	raw, err := c.do(ctx, as{account: account, user: user}, http.MethodGet, "/api/v1/content/read",
		url.Values{"uri": {uri}}, nil)
	if err != nil {
		return "", err
	}
	var text string
	if json.Unmarshal(raw, &text) != nil {
		return string(raw), nil
	}
	return text, nil
}

// Write replaces a file's text (creating it when missing).
func (c *Client) Write(ctx context.Context, account, user, uri, content string) error {
	_, err := c.do(ctx, as{account: account, user: user}, http.MethodPost, "/api/v1/content/write", nil,
		map[string]any{"uri": uri, "content": content, "mode": "replace"})
	return err
}

// Accounts lists the server's accounts whose id matches a pattern (* and ?).
func (c *Client) Accounts(ctx context.Context, pattern string) ([]string, error) {
	raw, err := c.do(ctx, as{}, http.MethodGet, "/api/v1/admin/accounts", url.Values{"name": {pattern}}, nil)
	if err != nil {
		return nil, err
	}
	var rows []struct {
		AccountID string `json:"account_id"`
	}
	if err := json.Unmarshal(raw, &rows); err != nil {
		return nil, err
	}
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		if r.AccountID != "" {
			out = append(out, r.AccountID)
		}
	}
	return out, nil
}

// Reindex recomputes the vectors under a uri of an account in the background
// (after the embedding model changed, the old vectors mean nothing).
func (c *Client) Reindex(ctx context.Context, account, uri string) error {
	_, err := c.do(ctx, as{account: account, user: "tradera", role: "admin"}, http.MethodPost,
		"/api/v1/content/reindex", nil,
		map[string]any{"uri": uri, "mode": "vectors_only", "wait": false, "recursive": true, "force": true})
	return err
}
