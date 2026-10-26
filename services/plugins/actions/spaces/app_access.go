package spaces

// App server access: the backend of an app served from the space's sandbox
// (an App UI OpenCode built, any proxied web service) uses the space's agents
// and apps through the same page API its pages use (_aseman/api/*), served to
// servers at the node's /appapi/v1/<op>. Every call runs as a person of the
// space and is billed to that person's wallet, through the same path a
// person's own ask takes (spaces.ask: funds check, then one charge for the
// bot's time and the turn's metered model usage, under the project's budget):
//
//   - User token: on every request the preview gateway forwards to the app,
//     it adds a short-lived token of the person using the app
//     (X-Aseman-User-Token). Work the server does for that request runs as,
//     and is billed to, that person.
//   - App key: work nobody is in front of (a schedule, a webhook, a queue)
//     uses the app's key (ASEMAN_APP_KEY, given to the app when it is built).
//     It runs as, and is billed to, the person who asked for the app, while
//     they are still a member of the space. The key is stored hashed, rotates
//     on every rebuild, and stops working when the app's preview is deleted.

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/auth/models/account"
	"github.com/aseman/aseman/plugins/actions/spaces/models/proxy"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

const (
	// appUserTokenTTL bounds how long an app server may act for the person
	// whose request it is serving (long agent asks included).
	appUserTokenTTL = 15 * time.Minute
	appKeyPrefix    = "aak_"
)

// AppKey is an app's credential for work nobody is in front of: it acts for
// (and bills) the person who asked for the app.
type AppKey struct {
	entity.Entity
	// AppID names the app (its project directory); one key per app.
	AppID   string      `db:"app_id" json:"app_id"`
	SpaceID identity.ID `db:"space_id" json:"space_id"`
	RoomID  identity.ID `db:"room_id" json:"room_id,omitempty"`
	// ProxyID is the app's preview; the key ends with it.
	ProxyID string `db:"proxy_id" json:"proxy_id,omitempty"`
	// OwnerID is the person who asked for the app: background work is theirs.
	OwnerID identity.ID `db:"owner_id" json:"owner_id"`
	Title   string      `db:"title" json:"title"`
	// Hash is the SHA-256 of the key's secret; the secret is never stored.
	Hash string `db:"hash" json:"-"`
}

// appSecret is the node's key for app user tokens, derived from its private
// key so tokens survive restarts and never leave the node.
func (s *Service) appSecret() ([]byte, error) {
	master := s.K.Env()["node_private_key"]
	if master == "" {
		return nil, errs.New(errs.CodeUnavailable, "node credential signing is not available")
	}
	mac := hmac.New(sha256.New, []byte(master))
	mac.Write([]byte("spaces/app-user-token"))
	return mac.Sum(nil), nil
}

type appUserClaims struct {
	Proxy string `json:"p"`
	User  string `json:"u"`
	Exp   int64  `json:"e"`
}

// AppUserToken is the token the gateway hands an app with each request of
// [viewer]: the app's server acts for (and bills) that person with it.
func (s *Service) AppUserToken(p *proxy.Proxy, viewer identity.ID) (string, error) {
	return s.signAppClaims(appUserClaims{Proxy: p.ID.String(), User: viewer.String(), Exp: time.Now().Add(appUserTokenTTL).Unix()})
}

func (s *Service) signAppClaims(c appUserClaims) (string, error) {
	key, err := s.appSecret()
	if err != nil {
		return "", err
	}
	b, _ := json.Marshal(c)
	body := base64.RawURLEncoding.EncodeToString(b)
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(body))
	return body + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), nil
}

// IssueAppKey creates (or rotates) the key of an app for its [owner], the
// person who asked for it. The returned key is shown once: only its hash is kept.
func (s *Service) IssueAppKey(ctx context.Context, spaceID, roomID, owner identity.ID, appID, title string) (string, error) {
	if owner.IsZero() || s.isBotAccount(ctx, owner) {
		return "", errs.InvalidArgument("an app key belongs to a person")
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", err
	}
	plain := base64.RawURLEncoding.EncodeToString(secret)
	now := time.Now().UTC()
	var existing []AppKey
	_ = s.R.List(ctx, "app_keys", database.Filter{Equal: map[string]any{"app_id": appID, "space_id": spaceID.String()}, Limit: 1}, &existing)
	if len(existing) > 0 {
		k := existing[0]
		k.RoomID, k.OwnerID, k.Title, k.Hash, k.UpdatedAt = roomID, owner, title, hashAppSecret(plain), now
		if err := s.R.Update(ctx, "app_keys", k.ID, &k); err != nil {
			return "", err
		}
		return appKeyPrefix + k.ID.String() + "." + plain, nil
	}
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return "", err
	}
	k := &AppKey{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, AppID: appID, SpaceID: spaceID,
		RoomID: roomID, OwnerID: owner, Title: title, Hash: hashAppSecret(plain)}
	if err := s.R.CreateID(ctx, "app_keys", id, k); err != nil {
		return "", err
	}
	return appKeyPrefix + id.String() + "." + plain, nil
}

// BindAppKey ties an app's key to its preview: the key works only while the
// preview exists.
func (s *Service) BindAppKey(ctx context.Context, spaceID identity.ID, appID string, proxyID identity.ID) error {
	var keys []AppKey
	if err := s.R.List(ctx, "app_keys", database.Filter{Equal: map[string]any{"app_id": appID, "space_id": spaceID.String()}, Limit: 1}, &keys); err != nil {
		return err
	}
	if len(keys) == 0 {
		return errs.NotFound("no key for this app")
	}
	k := keys[0]
	k.ProxyID, k.UpdatedAt = proxyID.String(), time.Now().UTC()
	return s.R.Update(ctx, "app_keys", k.ID, &k)
}

// AppCaller resolves the credential an app server presents (a user token or
// the app's key) to who the call runs as. The person must still be a member
// of the app's space, and a user token is good only for its own preview.
func (s *Service) AppCaller(ctx context.Context, token string) (*proxy.Access, error) {
	token = strings.TrimSpace(token)
	var (
		p      *proxy.Proxy
		person identity.ID
		via    string
	)
	if rest, ok := strings.CutPrefix(token, appKeyPrefix); ok {
		idPart, secret, _ := strings.Cut(rest, ".")
		id, err := identity.Parse(idPart)
		if err != nil || secret == "" {
			return nil, errs.Unauthenticated("invalid app key")
		}
		var k AppKey
		if err := s.R.Get(ctx, "app_keys", id, &k); err != nil {
			return nil, errs.Unauthenticated("invalid app key")
		}
		if subtle.ConstantTimeCompare([]byte(hashAppSecret(secret)), []byte(k.Hash)) != 1 {
			return nil, errs.Unauthenticated("invalid app key")
		}
		if k.ProxyID == "" {
			// Built, not yet served: scope it to where it was asked for.
			p = &proxy.Proxy{SpaceID: k.SpaceID, RoomID: k.RoomID, Title: k.Title}
		} else {
			pid, err := identity.Parse(k.ProxyID)
			if err != nil {
				return nil, errs.Unauthenticated("invalid app key")
			}
			if p, err = s.ProxyGet(ctx, pid); err != nil {
				return nil, errs.Unauthenticated("this app's preview was deleted; its key no longer works")
			}
		}
		person, via = k.OwnerID, "app "+k.Title+" (background)"
	} else {
		claims, err := s.openAppUserToken(token)
		if err != nil {
			return nil, err
		}
		pid, err := identity.Parse(claims.Proxy)
		if err != nil {
			return nil, errs.Unauthenticated("invalid app user token")
		}
		if person, err = identity.Parse(claims.User); err != nil {
			return nil, errs.Unauthenticated("invalid app user token")
		}
		if p, err = s.ProxyGet(ctx, pid); err != nil {
			return nil, errs.Unauthenticated("this app's preview was deleted")
		}
		via = "app " + p.Title
	}
	if _, err := s.SpaceMembership(ctx, p.SpaceID, person); err != nil {
		return nil, errs.Permission("the person this app acts for is no longer a member of its space")
	}
	var acc account.Account
	if err := s.R.Get(ctx, "accounts", person, &acc); err != nil {
		return nil, errs.Unauthenticated("the person this app acts for is unknown")
	}
	if acc.Kind == account.KindBot || acc.Status != account.StatusActive {
		return nil, errs.Permission("the person this app acts for cannot be billed")
	}
	return &proxy.Access{Proxy: p, Payer: &acc, Via: strings.TrimSpace(via)}, nil
}

func (s *Service) openAppUserToken(token string) (appUserClaims, error) {
	var c appUserClaims
	body, sig, ok := strings.Cut(token, ".")
	if !ok {
		return c, errs.Unauthenticated("invalid app user token")
	}
	key, err := s.appSecret()
	if err != nil {
		return c, err
	}
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(body))
	want := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	if !hmac.Equal([]byte(want), []byte(sig)) {
		return c, errs.Unauthenticated("invalid app user token")
	}
	raw, err := base64.RawURLEncoding.DecodeString(body)
	if err != nil || json.Unmarshal(raw, &c) != nil {
		return c, errs.Unauthenticated("invalid app user token")
	}
	if time.Now().Unix() > c.Exp {
		return c, errs.Unauthenticated("app user token expired; use the token of the request you are serving")
	}
	return c, nil
}

func hashAppSecret(secret string) string {
	sum := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(sum[:])
}

// AppAPIURL is where app servers in a sandbox reach the node's app API.
func (s *Service) AppAPIURL() string { return sandboxAppAPIURL() }

func sandboxAppAPIURL() string {
	if u := strings.TrimSpace(os.Getenv("ASEMAN_SANDBOX_APP_API_URL")); u != "" {
		return strings.TrimRight(u, "/")
	}
	base := strings.TrimSuffix(sandboxLLMBaseURL(), "/deepagents/v1/llm")
	if u, err := url.Parse(base); err != nil || u.Host == "" {
		base = "http://aseman:8080"
	}
	return strings.TrimRight(base, "/") + "/appapi/v1"
}
