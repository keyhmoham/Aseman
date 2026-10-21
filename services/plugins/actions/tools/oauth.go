package tools

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/idutil"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/tools/models"
	"net/http"
	"net/url"
	"strings"
	"time"
)

func oauthActions(s *Service) []api.Action {
	return []api.Action{helper.Action{Namespace: "tools", Name: "oauth_prepare", Summary: "Discover OAuth and prepare a PKCE grant", Handler: s.oauthPrepare}, helper.Action{Namespace: "tools", Name: "oauth_exchange", Summary: "Exchange an account-bound PKCE grant", Handler: s.oauthExchange}}
}
func (s *Service) oauthPrepare(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		URL          string `json:"url"`
		Redirect     string `json:"redirect_uri"`
		ClientID     string `json:"client_id"`
		ClientSecret string `json:"client_secret"`
		// Bot is the registered server being signed in to. The client its
		// administrator saved for it, if any, is used.
		Bot string `json:"bot"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	var shared oauthClient
	if in.Bot != "" {
		var tool models.Tool
		if e := s.R.GetString(ctx, "tool_registry", in.Bot, &tool); e != nil {
			return nil, e
		}
		// A client typed in by the person is theirs to use; the saved one is not mixed with it.
		if in.ClientID == "" {
			shared = s.oauthClientOf(&tool)
		}
		// The saved client only ever signs in to the server it was saved for:
		// its secret is sent to that server's token endpoint and no other.
		if shared.ClientID != "" || in.URL == "" {
			in.URL = tool.URL
		}
	}
	resource, e := url.Parse(in.URL)
	if e != nil || resource.Host == "" {
		return nil, errs.InvalidArgument("invalid MCP URL")
	}
	redirect, e := url.Parse(in.Redirect)
	if e != nil || redirect.Scheme == "" {
		return nil, errs.InvalidArgument("redirect URI required")
	}
	endpoint, tokenEndpoint := shared.AuthorizationEndpoint, shared.TokenEndpoint
	found := &oauthDiscovery{Resource: resource.String()}
	authorization := map[string]any{}
	// A server describes its own sign-in; endpoints saved by hand replace that.
	if endpoint == "" || tokenEndpoint == "" {
		discovered, ok := s.discoverOAuth(ctx, resource)
		if !ok {
			return nil, errs.New(errs.CodeUnavailable, "OAuth metadata could not be discovered")
		}
		found, authorization = discovered, discovered.Authorization
		if endpoint == "" {
			endpoint, _ = authorization["authorization_endpoint"].(string)
		}
		if tokenEndpoint == "" {
			tokenEndpoint, _ = authorization["token_endpoint"].(string)
		}
	}
	if endpoint == "" || tokenEndpoint == "" {
		return nil, errs.InvalidArgument("OAuth server lacks authorization or token endpoint")
	}
	scopes := strings.Join(found.Scopes, " ")
	if shared.Scopes != "" {
		scopes = shared.Scopes
	}
	clientID := in.ClientID
	clientSecret := in.ClientSecret
	if clientID == "" && shared.ClientID != "" {
		clientID, clientSecret = shared.ClientID, shared.ClientSecret
	}
	if clientID == "" {
		registration, _ := authorization["registration_endpoint"].(string)
		if registration != "" {
			registered, _, e := s.Client.FetchJSON(ctx, registration, nil, http.MethodPost, map[string]any{"client_name": "Aseman", "redirect_uris": []string{in.Redirect}, "grant_types": []string{"authorization_code", "refresh_token"}, "response_types": []string{"code"}, "token_endpoint_auth_method": "none"})
			if e == nil {
				clientID, _ = registered["client_id"].(string)
				clientSecret, _ = registered["client_secret"].(string)
			}
		}
	}
	if clientID == "" {
		return helper.JSON(map[string]any{"needs_client": true, "redirect_uri": in.Redirect, "error": "Create an OAuth client with this redirect URI and supply its client ID."})
	}
	state, e := idutil.RandomHex(32)
	if e != nil {
		return nil, e
	}
	verifier, e := idutil.RandomHex(32)
	if e != nil {
		return nil, e
	}
	sum := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(sum[:])
	grant := map[string]any{"client_id": clientID, "client_secret": clientSecret, "redirect_uri": in.Redirect, "verifier": verifier, "token_endpoint": tokenEndpoint, "resource": found.Resource}
	sealed, e := s.seal(grant)
	if e != nil {
		return nil, e
	}
	key := s.key("oauth/" + state)
	if e = s.R.CreateID(ctx, "tool_oauth", identity.MustParse(key), &models.OAuth{ID: key, Owner: req.Caller.ID.String(), Status: "pending", Secret: sealed, ExpiresAt: time.Now().UTC().Add(10 * time.Minute)}); e != nil {
		return nil, e
	}
	u, e := url.Parse(endpoint)
	if e != nil {
		return nil, e
	}
	q := u.Query()
	q.Set("client_id", clientID)
	q.Set("redirect_uri", in.Redirect)
	q.Set("response_type", "code")
	q.Set("state", state)
	q.Set("code_challenge", challenge)
	q.Set("code_challenge_method", "S256")
	q.Set("resource", found.Resource)
	if scopes != "" {
		q.Set("scope", scopes)
	}
	for k, v := range shared.Params {
		if v == "" {
			q.Del(k)
		} else {
			q.Set(k, v)
		}
	}
	u.RawQuery = q.Encode()
	return helper.JSON(map[string]any{"authorization_url": u.String(), "state": state})
}
func (s *Service) oauthExchange(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if e := helper.RequireUser(req); e != nil {
		return nil, e
	}
	var in struct {
		State string `json:"state"`
		Code  string `json:"code"`
	}
	if e := helper.Decode(req, &in); e != nil {
		return nil, e
	}
	if in.Code == "" {
		return nil, errs.InvalidArgument("OAuth code required")
	}
	key := s.key("oauth/" + in.State)
	var grant models.OAuth
	if e := s.R.GetString(ctx, "tool_oauth", key, &grant); e != nil {
		return nil, e
	}
	if grant.Owner != req.Caller.ID.String() {
		return nil, errs.Permission("OAuth grant belongs to another account")
	}
	if grant.ExpiresAt.Before(time.Now()) {
		return nil, errs.Unauthenticated("OAuth grant expired")
	}
	if grant.Status != "pending" {
		return nil, errs.Conflict("OAuth grant already exchanged")
	}
	grant.Status = "exchanging"
	changed, e := s.R.CompareAndSwap(ctx, "tool_oauth", key, map[string]any{"status": "pending"}, &grant)
	if e != nil {
		return nil, e
	}
	if !changed {
		return nil, errs.Conflict("OAuth grant already claimed")
	}
	secret, e := s.open(grant.Secret)
	if e != nil {
		return nil, e
	}
	field := func(k string) string { v, _ := secret[k].(string); return v }
	form := url.Values{"grant_type": {"authorization_code"}, "code": {in.Code}, "client_id": {field("client_id")}, "redirect_uri": {field("redirect_uri")}, "code_verifier": {field("verifier")}, "resource": {field("resource")}}
	if field("client_secret") != "" {
		form.Set("client_secret", field("client_secret"))
	}
	if field("resource") == "" {
		form.Del("resource")
	}
	token, e := s.tokenRequest(ctx, field("token_endpoint"), form)
	if e != nil {
		grant.Status = "failed"
		_ = s.R.UpdateString(ctx, "tool_oauth", key, &grant)
		return nil, e
	}
	access, _ := token["access_token"].(string)
	expires := expiresAt(token)
	// Kept with what the sign-in used, so the connection made from it can be
	// renewed later without the person (see connectionSet's grant).
	secret["access_token"] = access
	secret["refresh_token"] = token["refresh_token"]
	if expires != nil {
		secret["expires_at"] = expires.Format(time.RFC3339)
	}
	grant.Status = "used"
	grant.Secret, e = s.seal(secret)
	if e != nil {
		return nil, e
	}
	if e = s.R.UpdateString(ctx, "tool_oauth", key, &grant); e != nil {
		return nil, e
	}
	out := map[string]any{"access_token": access, "refresh_token": token["refresh_token"]}
	if expires != nil {
		out["expires_at"] = *expires
	}
	return helper.JSON(out)
}
