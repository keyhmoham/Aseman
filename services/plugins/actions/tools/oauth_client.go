package tools

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/support/helper"
	"github.com/tradera/tradera/plugins/actions/tools/mechanisms/mcp"
	"github.com/tradera/tradera/plugins/actions/tools/models"
)

// oauthClient is the OAuth client everyone signs in to a server with. Most
// servers let a client register itself and need none. A provider that does not
// (GitHub, Google, Slack, ...) has its administrator create one by hand and
// save it here: it is kept sealed with the server's other secrets and used for
// each person's sign-in, so nobody else ever handles it.
//
// Everything past the id and secret is optional, for providers whose server
// does not describe its own sign-in: the two endpoints, the scopes to ask for,
// and extra parameters for the sign-in page (a parameter with an empty value
// removes one that would otherwise be sent).
type oauthClient struct {
	ClientID              string            `json:"client_id"`
	ClientSecret          string            `json:"client_secret,omitempty"`
	AuthorizationEndpoint string            `json:"authorization_endpoint,omitempty"`
	TokenEndpoint         string            `json:"token_endpoint,omitempty"`
	Scopes                string            `json:"scopes,omitempty"`
	Params                map[string]string `json:"params,omitempty"`
}

// oauthClientOf reads the client saved for a server; ClientID is empty when
// there is none.
func (s *Service) oauthClientOf(tool *models.Tool) oauthClient {
	var out oauthClient
	secret, e := s.open(tool.Secrets)
	if e != nil {
		return out
	}
	if raw, ok := secret["oauth"]; ok {
		if b, e := json.Marshal(raw); e == nil {
			_ = json.Unmarshal(b, &out)
		}
	}
	return out
}

// ownedTool loads a registered server its owner or an administrator may change.
func (s *Service) ownedTool(ctx context.Context, req *api.ActionRequest, botID string) (*models.Tool, error) {
	var tool models.Tool
	if e := s.R.GetString(ctx, "tool_registry", botID, &tool); e != nil {
		return nil, e
	}
	if tool.Owner != req.Caller.ID.String() && helper.RequireNodeAdmin(ctx, s.R, req, s.K.Env()["admin_handle"]) != nil {
		return nil, errs.Permission("tool owner or administrator required")
	}
	return &tool, nil
}

func clientView(c oauthClient) map[string]any {
	return map[string]any{
		"client_id":              c.ClientID,
		"has_secret":             c.ClientSecret != "",
		"authorization_endpoint": c.AuthorizationEndpoint,
		"token_endpoint":         c.TokenEndpoint,
		"scopes":                 c.Scopes,
		"params":                 url.Values(paramValues(c.Params)).Encode(),
	}
}

func paramValues(params map[string]string) map[string][]string {
	out := map[string][]string{}
	for k, v := range params {
		out[k] = []string{v}
	}
	return out
}

// mcpOAuthGet shows the client saved for a server, without its secret.
func (s *Service) mcpOAuthGet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		Bot string `json:"bot"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	tool, e := s.ownedTool(ctx, req, in.Bot)
	if e != nil {
		return nil, e
	}
	return helper.JSON(clientView(s.oauthClientOf(tool)))
}

// mcpOAuthSet saves, changes or (with an empty client id) removes the client
// people sign in to a server with.
func (s *Service) mcpOAuthSet(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		Bot      string `json:"bot"`
		ClientID string `json:"client_id"`
		// ClientSecret left out keeps the one saved.
		ClientSecret          *string `json:"client_secret"`
		AuthorizationEndpoint string  `json:"authorization_endpoint"`
		TokenEndpoint         string  `json:"token_endpoint"`
		Scopes                string  `json:"scopes"`
		// Params is a query string: access_type=offline&prompt=consent
		Params string `json:"params"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	tool, e := s.ownedTool(ctx, req, in.Bot)
	if e != nil {
		return nil, e
	}
	before := s.oauthClientOf(tool)
	next := oauthClient{
		ClientID:              strings.TrimSpace(in.ClientID),
		ClientSecret:          before.ClientSecret,
		AuthorizationEndpoint: strings.TrimSpace(in.AuthorizationEndpoint),
		TokenEndpoint:         strings.TrimSpace(in.TokenEndpoint),
		Scopes:                strings.Join(strings.Fields(strings.ReplaceAll(in.Scopes, ",", " ")), " "),
	}
	if in.ClientSecret != nil {
		next.ClientSecret = strings.TrimSpace(*in.ClientSecret)
	}
	for _, endpoint := range []string{next.AuthorizationEndpoint, next.TokenEndpoint} {
		if endpoint == "" {
			continue
		}
		if e := mcp.ValidURL(endpoint); e != nil {
			return nil, errs.InvalidArgument(e.Error())
		}
	}
	if text := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(in.Params), "?")); text != "" {
		values, e := url.ParseQuery(text)
		if e != nil {
			return nil, errs.InvalidArgument("extra parameters must look like name=value&other=value")
		}
		next.Params = map[string]string{}
		for k := range values {
			next.Params[k] = values.Get(k)
		}
	}
	secret, e := s.open(tool.Secrets)
	if e != nil {
		return nil, e
	}
	if next.Scopes == "" {
		// A sample knows what it needs; the provider's own list can be everything it has.
		for _, sample := range sampleServers {
			if sample.URL == tool.URL {
				next.Scopes = sample.Scopes
			}
		}
	}
	if next.ClientID == "" {
		next = oauthClient{}
		delete(secret, "oauth")
	} else {
		secret["oauth"] = next
	}
	if tool.Secrets, e = s.seal(secret); e != nil {
		return nil, e
	}
	tool.UpdatedAt = time.Now().UTC()
	if e = s.R.UpdateString(ctx, "tool_registry", tool.ID, tool); e != nil {
		return nil, e
	}
	// The catalog says whether a server is ready for people to sign in to.
	if descriptor := s.descriptorOf(ctx, req, tool.BotID); descriptor != nil {
		if kind, _ := descriptor["kind"].(string); kind == "mcp" {
			switch {
			case next.ClientID != "":
				descriptor["mcp_client"] = "set"
			case sampleNeedsClient(tool.URL):
				descriptor["mcp_client"] = "required"
			default:
				delete(descriptor, "mcp_client")
			}
			body, _ := json.Marshal(map[string]any{"bot": tool.BotID, "descriptor": descriptor})
			if _, e = s.K.Actions().Dispatch(ctx, "bots", "bot_edit", &api.ActionRequest{Caller: req.Caller, Body: body}); e != nil {
				return nil, e
			}
		}
	}
	return helper.JSON(clientView(next))
}

// tokenResponse reads a token endpoint's answer. The standard is JSON; some
// providers answer as a form unless asked otherwise.
func tokenResponse(body []byte) map[string]any {
	var out map[string]any
	if json.Unmarshal(body, &out) == nil && out != nil {
		return out
	}
	out = map[string]any{}
	if values, e := url.ParseQuery(strings.TrimSpace(string(body))); e == nil {
		for k := range values {
			out[k] = values.Get(k)
		}
	}
	return out
}

// expiresAt is when a token response says its access token stops working.
func expiresAt(token map[string]any) *time.Time {
	seconds := 0.0
	switch v := token["expires_in"].(type) {
	case float64:
		seconds = v
	case string:
		seconds, _ = strconv.ParseFloat(v, 64)
	}
	if seconds <= 0 {
		return nil
	}
	at := time.Now().UTC().Add(time.Duration(seconds) * time.Second)
	return &at
}

// tokenRequest posts a grant to a token endpoint and returns what it answers.
func (s *Service) tokenRequest(ctx context.Context, endpoint string, form url.Values) (map[string]any, error) {
	request, e := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if e != nil {
		return nil, e
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	request.Header.Set("Accept", "application/json")
	response, e := s.Client.HTTP.Do(request)
	if e != nil {
		return nil, e
	}
	defer response.Body.Close()
	body, e := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if e != nil {
		return nil, e
	}
	token := tokenResponse(body)
	if access, _ := token["access_token"].(string); response.StatusCode >= 300 || access == "" {
		reason, _ := token["error_description"].(string)
		if reason == "" {
			reason, _ = token["error"].(string)
		}
		if reason == "" {
			reason = "no access token returned"
		}
		return nil, errs.Unauthenticated("the provider refused: " + reason)
	}
	return token, nil
}

var refreshMu sync.Mutex

// refreshConnection renews a person's sign-in with the refresh token kept from
// it, and saves the new one. It needs what the sign-in recorded: a connection
// made by pasting a token cannot be renewed.
func (s *Service) refreshConnection(ctx context.Context, row *models.Connection, secret map[string]any) (map[string]any, error) {
	refreshMu.Lock()
	defer refreshMu.Unlock()
	// Someone else may have renewed it while this call waited.
	var fresh models.Connection
	if e := s.R.GetString(ctx, "tool_connections", row.ID, &fresh); e == nil && fresh.Secret != row.Secret {
		if opened, e := s.open(fresh.Secret); e == nil {
			*row = fresh
			return opened, nil
		}
	}
	field := func(k string) string { v, _ := secret[k].(string); return v }
	if field("refresh_token") == "" || field("token_endpoint") == "" {
		return nil, errs.Unauthenticated("this connection cannot be renewed")
	}
	form := url.Values{"grant_type": {"refresh_token"}, "refresh_token": {field("refresh_token")}, "client_id": {field("client_id")}}
	if field("client_secret") != "" {
		form.Set("client_secret", field("client_secret"))
	}
	if field("resource") != "" {
		form.Set("resource", field("resource"))
	}
	token, e := s.tokenRequest(ctx, field("token_endpoint"), form)
	if e != nil {
		return nil, e
	}
	secret["token"] = token["access_token"]
	// Providers that rotate refresh tokens send the next one; others keep it.
	if next, _ := token["refresh_token"].(string); next != "" {
		secret["refresh_token"] = next
	}
	sealed, e := s.seal(secret)
	if e != nil {
		return nil, e
	}
	row.Secret = sealed
	row.ExpiresAt = expiresAt(token)
	row.UpdatedAt = time.Now().UTC()
	if e = s.R.UpdateString(ctx, "tool_connections", row.ID, row); e != nil {
		return nil, e
	}
	return secret, nil
}
