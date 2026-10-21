package timeline

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/pkg/errs"
)

// utopia talks to the node's Utopia server (https://github.com/deeplethe/utopia),
// the bitemporal knowledge graph the spaces' timelines live in. The node signs
// in as one service account (the first account of a fresh Utopia becomes its
// administrator), keeps one knowledge base per space, pushes events through a
// statements source per base and reads them back over each base's MCP server.
type utopia struct {
	base     string
	email    string
	password string
	http     *http.Client

	mu        sync.Mutex
	jwt       string
	workspace string
}

// errNotFound marks a base, source or token Utopia no longer knows (its data
// was reset): the node provisions it again.
var errNotFound = errs.New(errs.CodeNotFound, "utopia: not found")

func newUtopia(base, email, password string) *utopia {
	return &utopia{base: strings.TrimRight(base, "/") + "/api/v1", email: email, password: password,
		http: &http.Client{Timeout: 60 * time.Second}}
}

// do sends one request; auth is the bearer (a session, a push key or a token).
func (u *utopia) do(ctx context.Context, method, path, auth string, body, out any) error {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, u.base+path, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if auth != "" {
		req.Header.Set("Authorization", "Bearer "+auth)
	}
	resp, err := u.http.Do(req)
	if err != nil {
		return errs.Wrap(errs.CodeUnavailable, err, "utopia unreachable")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return errs.Wrap(errs.CodeUnavailable, err, "utopia response")
	}
	switch {
	case resp.StatusCode == http.StatusNotFound:
		return errNotFound
	case resp.StatusCode == http.StatusUnauthorized:
		return errs.Unauthenticated("utopia: " + clip(string(data), 300))
	case resp.StatusCode >= 300:
		return errs.New(errs.CodeUnavailable, fmt.Sprintf("utopia %s %s: %d %s", method, path, resp.StatusCode, clip(string(data), 300)))
	}
	if out == nil {
		return nil
	}
	if raw, ok := out.(*[]byte); ok {
		*raw = data
		return nil
	}
	if err := json.Unmarshal(data, out); err != nil {
		return errs.Wrap(errs.CodeUnavailable, err, "decode utopia response")
	}
	return nil
}

// session returns a signed-in session, signing in (or, on a fresh Utopia,
// registering the service account) when there is none.
func (u *utopia) session(ctx context.Context) (string, string, error) {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.jwt != "" && u.workspace != "" {
		return u.jwt, u.workspace, nil
	}
	var auth struct {
		Token string `json:"token"`
	}
	creds := map[string]any{"email": u.email, "password": u.password}
	err := u.do(ctx, http.MethodPost, "/auth/login", "", creds, &auth)
	if err != nil && errs.CodeOf(err) != errs.CodeUnavailable {
		// No such account yet: register it. On a fresh Utopia the first
		// account is its administrator.
		reg := map[string]any{"email": u.email, "password": u.password, "display_name": "Aseman"}
		if regErr := u.do(ctx, http.MethodPost, "/auth/register", "", reg, &auth); regErr != nil {
			return "", "", errs.Wrap(errs.CodeUnavailable, regErr, "utopia: cannot sign in or register the node's account ("+err.Error()+")")
		}
	} else if err != nil {
		return "", "", err
	}
	if auth.Token == "" {
		return "", "", errs.New(errs.CodeUnavailable, "utopia: sign-in returned no session")
	}
	var workspaces []struct {
		ID string `json:"id"`
	}
	if err := u.do(ctx, http.MethodGet, "/workspaces", auth.Token, nil, &workspaces); err != nil {
		return "", "", err
	}
	if len(workspaces) == 0 {
		return "", "", errs.New(errs.CodeUnavailable, "utopia: the node's account has no workspace")
	}
	u.jwt, u.workspace = auth.Token, workspaces[0].ID
	return u.jwt, u.workspace, nil
}

// admin runs one call with the session, signing in again once if it expired.
func (u *utopia) admin(ctx context.Context, call func(jwt, workspace string) error) error {
	jwt, ws, err := u.session(ctx)
	if err != nil {
		return err
	}
	err = call(jwt, ws)
	if errs.CodeOf(err) == errs.CodeUnauthenticated {
		u.mu.Lock()
		u.jwt = ""
		u.mu.Unlock()
		if jwt, ws, err = u.session(ctx); err != nil {
			return err
		}
		err = call(jwt, ws)
	}
	return err
}

// createBase creates a space's knowledge base and its statements source.
func (u *utopia) createBase(ctx context.Context, name, description string) (kbID, sourceID, pushKey string, err error) {
	err = u.admin(ctx, func(jwt, ws string) error {
		var kb struct {
			ID string `json:"id"`
		}
		body := map[string]any{"name": name, "kind": "knowledge", "visibility": "restricted", "description": description}
		if err := u.do(ctx, http.MethodPost, "/workspaces/"+ws+"/kbs", jwt, body, &kb); err != nil {
			return err
		}
		var src struct {
			Source struct {
				ID string `json:"id"`
			} `json:"source"`
			IngestToken string `json:"ingest_token"`
		}
		if err := u.do(ctx, http.MethodPost, "/kbs/"+kb.ID+"/sources", jwt,
			map[string]any{"kind": "statements", "name": "Aseman events"}, &src); err != nil {
			return err
		}
		if kb.ID == "" || src.Source.ID == "" || src.IngestToken == "" {
			return errs.New(errs.CodeUnavailable, "utopia: incomplete knowledge base")
		}
		kbID, sourceID, pushKey = kb.ID, src.Source.ID, src.IngestToken
		return nil
	})
	return
}

// issueReadToken issues the node's read-only personal token (never expires).
func (u *utopia) issueReadToken(ctx context.Context) (string, error) {
	var out struct {
		Token string `json:"token"`
	}
	err := u.admin(ctx, func(jwt, _ string) error {
		body := map[string]any{"name": "aseman-agents", "scope": "read", "expires_in_days": 0}
		return u.do(ctx, http.MethodPost, "/me/tokens", jwt, body, &out)
	})
	if err == nil && out.Token == "" {
		err = errs.New(errs.CodeUnavailable, "utopia: no token issued")
	}
	return out.Token, err
}

// push sends one observation in the statements contract; it answers what
// Utopia did (created, updated, unchanged …).
func (u *utopia) push(ctx context.Context, sourceID, pushKey string, item observation) (string, error) {
	var out struct {
		Action string `json:"action"`
	}
	err := u.do(ctx, http.MethodPost, "/sources/"+sourceID+"/statements", pushKey, item, &out)
	return out.Action, err
}

// mcp forwards one JSON-RPC message to a base's MCP server.
func (u *utopia) mcp(ctx context.Context, kbID, token string, body []byte) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.base+"/kbs/"+kbID+"/mcp", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := u.http.Do(req)
	if err != nil {
		return nil, errs.Wrap(errs.CodeUnavailable, err, "utopia unreachable")
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, errs.Wrap(errs.CodeUnavailable, err, "utopia response")
	}
	switch {
	case resp.StatusCode == http.StatusNotFound:
		return nil, errNotFound
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return nil, errs.Unauthenticated("utopia rejected the node's read token")
	case resp.StatusCode >= 300:
		return nil, errs.New(errs.CodeUnavailable, fmt.Sprintf("utopia mcp: %d %s", resp.StatusCode, clip(string(data), 300)))
	}
	return data, nil
}

func clip(s string, n int) string {
	s = strings.TrimSpace(s)
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}
