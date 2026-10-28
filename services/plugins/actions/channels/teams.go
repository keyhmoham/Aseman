package channels

import (
	"bytes"
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/replies"
	cm "github.com/aseman/aseman/plugins/actions/channels/models"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// Microsoft Teams, through the Bot Framework: activities arrive at
// TeamsMessagesPath with a bearer token signed by the Bot Framework (checked
// against its published keys, issuer and the app's id as audience); replies
// go to the conversation's service URL with a token for the app.
const TeamsMessagesPath = "/channels/v1/teams/messages"

const botFrameworkIssuer = "https://api.botframework.com"

// keyCache holds the Bot Framework's signing keys for a day.
type keyCache struct {
	mu      sync.Mutex
	keys    map[string]*rsa.PublicKey
	fetched time.Time
	// token is the app's own token for replies.
	token   string
	expires time.Time
}

func (s *Service) signingKey(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	c := s.jwks
	c.mu.Lock()
	defer c.mu.Unlock()
	if k, ok := c.keys[kid]; ok && time.Since(c.fetched) < 24*time.Hour {
		return k, nil
	}
	var meta struct {
		JWKS string `json:"jwks_uri"`
	}
	if err := s.getJSON(ctx, s.BotFrameworkOpenID, &meta); err != nil {
		return nil, err
	}
	var set struct {
		Keys []struct {
			Kid string `json:"kid"`
			N   string `json:"n"`
			E   string `json:"e"`
			Kty string `json:"kty"`
		} `json:"keys"`
	}
	if err := s.getJSON(ctx, meta.JWKS, &set); err != nil {
		return nil, err
	}
	c.keys = map[string]*rsa.PublicKey{}
	for _, k := range set.Keys {
		if k.Kty != "RSA" {
			continue
		}
		n, err1 := base64.RawURLEncoding.DecodeString(k.N)
		e, err2 := base64.RawURLEncoding.DecodeString(k.E)
		if err1 != nil || err2 != nil {
			continue
		}
		c.keys[k.Kid] = &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
	}
	c.fetched = time.Now()
	if k, ok := c.keys[kid]; ok {
		return k, nil
	}
	return nil, errs.Unauthenticated("unknown signing key")
}

func (s *Service) getJSON(ctx context.Context, u string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	resp, err := s.HTTP.Do(req)
	if err != nil {
		return errs.Wrap(errs.CodeUnavailable, err, "fetch")
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return errs.New(errs.CodeUnavailable, u+": "+resp.Status)
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(out)
}

// teamsVerified checks the activity's token.
func (s *Service) teamsVerified(ctx context.Context, appID string, req *network.Request) bool {
	raw := strings.TrimPrefix(headerOf(req.Header, "Authorization"), "Bearer ")
	if raw == "" || appID == "" {
		return false
	}
	_, err := jwt.Parse(raw, func(t *jwt.Token) (any, error) {
		kid, _ := t.Header["kid"].(string)
		return s.signingKey(ctx, kid)
	}, jwt.WithValidMethods([]string{"RS256"}), jwt.WithIssuer(botFrameworkIssuer), jwt.WithAudience(appID), jwt.WithLeeway(5*time.Minute))
	return err == nil
}

type activity struct {
	Type       string `json:"type"`
	ID         string `json:"id"`
	Text       string `json:"text"`
	ServiceURL string `json:"serviceUrl"`
	ChannelID  string `json:"channelId"`
	From       struct {
		ID          string `json:"id"`
		AADObjectID string `json:"aadObjectId"`
		Name        string `json:"name"`
	} `json:"from"`
	Recipient struct {
		ID string `json:"id"`
	} `json:"recipient"`
	Conversation struct {
		ID       string `json:"id"`
		TenantID string `json:"tenantId"`
	} `json:"conversation"`
	Value map[string]any `json:"value"`
}

func (s *Service) serveTeams(ctx context.Context, req *network.Request) (*network.Response, error) {
	st, err := s.settings(ctx, cm.Teams)
	if err != nil || !st.Enabled {
		return jsonReply(http.StatusNotFound, map[string]string{"error": "teams is not set up"}), nil
	}
	if !s.teamsVerified(ctx, st.AppID, req) {
		return jsonReply(http.StatusUnauthorized, map[string]string{"error": "token"}), nil
	}
	var a activity
	if err := json.Unmarshal(req.Body, &a); err != nil || a.Type != "message" {
		return &network.Response{Status: http.StatusOK}, nil
	}
	if st.Tenant != "" && a.Conversation.TenantID != st.Tenant {
		return &network.Response{Status: http.StatusOK}, nil
	}
	external := a.From.AADObjectID
	if external == "" {
		external = a.From.ID
	}
	where := &cm.Binding{External: external, Workspace: a.Conversation.TenantID, Conversation: a.Conversation.ID, ServiceURL: a.ServiceURL}
	text := strings.TrimSpace(stripTeamsMention(a.Text))
	if code, ok := linkCommand(text); ok {
		msg := s.redeem(ctx, cm.Teams, code, *where)
		_ = s.teamsSend(ctx, where, map[string]any{"type": "message", "text": msg, "replyToId": a.ID})
		return &network.Response{Status: http.StatusOK}, nil
	}
	b, ok := s.binding(ctx, cm.Teams, a.Conversation.TenantID, external)
	if !ok {
		_ = s.teamsSend(ctx, where, map[string]any{"type": "message", "text": "I don't know who you are in Aseman yet. In Aseman, open Settings → Channels → Teams, then send me: link <code>."})
		return &network.Response{Status: http.StatusOK}, nil
	}
	// The conversation the person writes from is where to answer them.
	if b.Conversation != a.Conversation.ID || b.ServiceURL != a.ServiceURL {
		b.Conversation, b.ServiceURL, b.UpdatedAt = a.Conversation.ID, a.ServiceURL, s.now().UTC()
		_ = s.R.Update(ctx, "channel_bindings", b.ID, b)
	}
	// An Adaptive Card's button: an approval, or a reply chip.
	if a.Value != nil {
		if id, _ := a.Value["approval"].(string); id != "" {
			answer, _ := a.Value["answer"].(string)
			caller, _ := parseID(b.AccountID)
			msg := answerWord(answer) + "."
			if err := s.Governance.Answer(ctx, caller, id, answer); err != nil {
				msg = "Couldn't answer: " + err.Error()
			}
			_ = s.teamsSend(ctx, b, map[string]any{"type": "message", "text": msg, "replyToId": a.ID})
			return &network.Response{Status: http.StatusOK}, nil
		}
		if r, _ := a.Value["reply"].(string); r != "" {
			text = r
		}
	}
	if text == "" {
		return &network.Response{Status: http.StatusOK}, nil
	}
	replyTo := a.ID
	s.converse(ctx, b, text, func(ctx context.Context, answer string) {
		body, chips := replies.Parse(answer)
		msg := map[string]any{"type": "message", "text": body, "replyToId": replyTo}
		if len(chips) > 0 {
			msg["attachments"] = []map[string]any{adaptiveCard(body, chipActions(chips))}
			msg["text"] = ""
		}
		if err := s.teamsSend(ctx, b, msg); err != nil {
			s.L.Warn("teams reply not sent", "error", err)
		}
	})
	return &network.Response{Status: http.StatusOK}, nil
}

func stripTeamsMention(text string) string {
	for strings.Contains(text, "<at>") {
		i, j := strings.Index(text, "<at>"), strings.Index(text, "</at>")
		if j < i {
			break
		}
		text = text[:i] + text[j+len("</at>"):]
	}
	return text
}

func adaptiveCard(text string, actions []map[string]any) map[string]any {
	return map[string]any{"contentType": "application/vnd.microsoft.card.adaptive", "content": map[string]any{
		"type": "AdaptiveCard", "version": "1.4", "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
		"body":    []map[string]any{{"type": "TextBlock", "text": text, "wrap": true}},
		"actions": actions,
	}}
}

func chipActions(chips []string) []map[string]any {
	var out []map[string]any
	for _, c := range chips {
		out = append(out, map[string]any{"type": "Action.Submit", "title": c, "data": map[string]string{"reply": c}})
	}
	return out
}

func (s *Service) teamsApproval(ctx context.Context, b *cm.Binding, note gate.ApprovalNote) error {
	actions := []map[string]any{
		{"type": "Action.Submit", "title": "Allow once", "style": "positive", "data": map[string]string{"approval": note.ID, "answer": "once"}},
		{"type": "Action.Submit", "title": "Always allow", "data": map[string]string{"approval": note.ID, "answer": "always"}},
		{"type": "Action.Submit", "title": "Refuse", "style": "destructive", "data": map[string]string{"approval": note.ID, "answer": "refuse"}},
	}
	return s.teamsSend(ctx, b, map[string]any{"type": "message", "attachments": []map[string]any{adaptiveCard("**Waiting for your approval**\n\n"+approvalText(note), actions)}})
}

// teamsSend posts an activity to the binding's conversation.
func (s *Service) teamsSend(ctx context.Context, b *cm.Binding, activity map[string]any) error {
	if b.ServiceURL == "" || b.Conversation == "" {
		return errs.InvalidArgument("no Teams conversation for this person yet: they write to the app first")
	}
	tok, err := s.teamsToken(ctx)
	if err != nil {
		return err
	}
	endpoint := strings.TrimRight(b.ServiceURL, "/") + "/v3/conversations/" + url.PathEscape(b.Conversation) + "/activities"
	if id, _ := activity["replyToId"].(string); id != "" {
		endpoint += "/" + url.PathEscape(id)
	}
	raw, _ := json.Marshal(activity)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := s.HTTP.Do(req)
	if err != nil {
		return errs.Wrap(errs.CodeUnavailable, err, "teams")
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return errs.New(errs.CodeUnavailable, fmt.Sprintf("teams: %s %s", resp.Status, data))
	}
	return nil
}

// teamsToken is the app's token for the Bot Connector.
func (s *Service) teamsToken(ctx context.Context) (string, error) {
	c := s.jwks
	c.mu.Lock()
	if c.token != "" && time.Now().Before(c.expires.Add(-time.Minute)) {
		defer c.mu.Unlock()
		return c.token, nil
	}
	c.mu.Unlock()
	st, err := s.settings(ctx, cm.Teams)
	if err != nil {
		return "", err
	}
	form := url.Values{"grant_type": {"client_credentials"}, "client_id": {st.AppID}, "client_secret": {st.secret},
		"scope": {"https://api.botframework.com/.default"}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.BotFrameworkToken, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := s.HTTP.Do(req)
	if err != nil {
		return "", errs.Wrap(errs.CodeUnavailable, err, "teams token")
	}
	defer resp.Body.Close()
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || out.AccessToken == "" {
		return "", errs.New(errs.CodeUnavailable, "teams: no token for the app")
	}
	c.mu.Lock()
	c.token, c.expires = out.AccessToken, time.Now().Add(time.Duration(out.ExpiresIn)*time.Second)
	c.mu.Unlock()
	return out.AccessToken, nil
}
