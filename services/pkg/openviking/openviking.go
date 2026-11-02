// Package openviking reaches the node's self-hosted OpenViking server, which
// keeps the agents' memory (https://openviking.ai). The deep agents runtime
// does most of the work there; the node only reads and edits the agents'
// notes for people and re-indexes memory when the admin changes the embedding
// model.
//
// The server runs in trusted mode: every request carries the root key and
// names the account and user it acts as. A space is an account, an agent a
// user of it; the identifiers below must match the runtime's
// (decillion_agents/memory.py).
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
	EnvURL = "ASEMAN_OPENVIKING_URL"
	EnvKey = "ASEMAN_OPENVIKING_API_KEY"
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

// PersonAccount is the account of a person's own memory: what their Aseman
// (their notes to themselves, Saved Messages) knows of them. Nothing of a space
// is in it, and nothing of it is in any space.
func PersonAccount(personID string) string { return id("person-", personID) }

// Peer is a person as OpenViking's peer: whom a recall is made for.
func Peer(personID string) string { return id("", personID) }

// The brain is the one user of a person's account: its notes about the person
// and the session of their notes to themselves.
const (
	BrainUser    = "aseman"
	BrainSession = "saved"
)

// BrainNotes is what the brain keeps about its person: lasting facts,
// preferences and instructions, one a line. It goes into every answer.
const BrainNotes = "viking://user/" + BrainUser + "/memories/notes.md"

// Resources is where a space's shared knowledge lives (its notes, the files
// people attached): what a person's brain may recall of a room it can read.
const Resources = "viking://resources"

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

// as says whom a request acts as (and, for a recall, whom it is made for).
type as struct {
	account, user, role, peer string
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
	if who.peer != "" {
		req.Header.Set("X-OpenViking-Actor-Peer", who.peer)
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

// Append adds text to the end of a file (creating it when missing). It is only
// embedded, not summarized: notes need to be found, and they are read whole.
func (c *Client) Append(ctx context.Context, account, user, uri, content string) error {
	_, err := c.do(ctx, as{account: account, user: user}, http.MethodPost, "/api/v1/content/write", nil,
		map[string]any{"uri": uri, "content": content, "mode": "append", "processing_mode": "vectors_only"})
	return err
}

// Recall says what to search and for whom.
type Recall struct {
	// Session is the conversation the query belongs to: OpenViking leaves out
	// what it is already showing and reads a follow-up in its light.
	Session string
	// Peer is the person the recall is for (their memories first).
	Peer string
	// Targets narrows the search to these uris (all of the account when empty).
	Targets []string
	// MaxTokens is the most the rendered result may hold.
	MaxTokens int
}

// Recall is what an account's memory holds about a query, rendered for a
// model ("" when nothing is relevant). The query is taken by its words and
// meaning only: expanding it would cost a model call on every message.
func (c *Client) Recall(ctx context.Context, account, user, query string, r Recall) (string, error) {
	if len(query) > 4000 {
		query = query[len(query)-4000:]
	}
	body := map[string]any{"query": query, "mode": "context", "limit": 10, "purpose": "chat",
		"query_expansion": "off", "max_tokens": max(r.MaxTokens, 64)}
	if r.Session != "" {
		body["session_id"] = r.Session
	}
	if len(r.Targets) > 0 {
		body["target_uri"] = r.Targets
	}
	raw, err := c.do(ctx, as{account: account, user: user, peer: r.Peer}, http.MethodPost, "/api/v1/search/search", nil, body)
	if err != nil {
		return "", err
	}
	var out struct {
		Rendered string `json:"rendered"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", err
	}
	return strings.TrimSpace(out.Rendered), nil
}

// Message is one message of a session: Role is "user" or "assistant".
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
	// PeerID is who said it, for a person's message.
	PeerID string `json:"peer_id,omitempty"`
}

// AddMessages adds messages to a session (creating it when missing).
// OpenViking archives the session and extracts long-term memories from it in
// the background, as its commit policy says.
func (c *Client) AddMessages(ctx context.Context, account, user, session string, messages []Message) error {
	_, err := c.do(ctx, as{account: account, user: user}, http.MethodPost,
		"/api/v1/sessions/"+url.PathEscape(session)+"/messages/batch", nil, map[string]any{"messages": messages})
	return err
}

// CommitPolicy is when OpenViking commits a session by itself (extracts its
// memories): once this many messages or tokens gathered, or once it has been
// quiet this long.
type CommitPolicy struct {
	Messages    int `json:"message_count_threshold"`
	Tokens      int `json:"pending_token_threshold"`
	IdleSeconds int `json:"idle_timeout_seconds"`
}

// SetCommitPolicy sets a session's commit policy. The session must exist.
func (c *Client) SetCommitPolicy(ctx context.Context, account, user, session string, p CommitPolicy) error {
	_, err := c.do(ctx, as{account: account, user: user}, http.MethodPatch,
		"/api/v1/sessions/"+url.PathEscape(session)+"/config", nil, map[string]any{"auto_commit_policy": p})
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
	_, err := c.do(ctx, as{account: account, user: "aseman", role: "admin"}, http.MethodPost,
		"/api/v1/content/reindex", nil,
		map[string]any{"uri": uri, "mode": "vectors_only", "wait": false, "recursive": true, "force": true})
	return err
}
