package users

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// Calls are peer to peer (WebRTC); a relay (TURN) carries the media of the
// calls whose two phones cannot reach each other directly. The app never knows
// who runs the relay: it asks the node for the ICE servers of a call and hands
// them to WebRTC, so changing provider is a node setting, not an app release.
//
//	ASEMAN_TURN_PROVIDER     cloudflare | coturn | stun (default: cloudflare when its
//	                            key is set, else coturn when its secret is set, else stun)
//	ASEMAN_TURN_CF_KEY_ID    Cloudflare Realtime TURN key id
//	ASEMAN_TURN_CF_API_TOKEN that key's API token
//	ASEMAN_TURN_URLS         coturn: comma-separated turn:/turns: urls
//	ASEMAN_TURN_SECRET       coturn: its static-auth-secret (TURN REST credentials)
//	ASEMAN_TURN_TTL          seconds credentials last (default 14400)
//
// Without any of them calls still work between phones that can reach each
// other (STUN only), and fail only where a relay would have been needed.

// ICEServer is one STUN/TURN entry, as WebRTC's RTCIceServer reads it.
type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

// stunOnly is the always-available fallback: it helps phones find each other
// but relays nothing.
var stunOnly = ICEServer{URLs: []string{"stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"}}

// cloudflareAPI is where the TURN key's credentials are minted (a variable so
// tests can point it elsewhere).
var cloudflareAPI = "https://rtc.live.cloudflare.com"

func turnTTL() time.Duration {
	if n, err := strconv.Atoi(strings.TrimSpace(os.Getenv("ASEMAN_TURN_TTL"))); err == nil && n >= 60 {
		return time.Duration(n) * time.Second
	}
	return 4 * time.Hour
}

// turnProvider is the configured relay: "cloudflare", "coturn" or "stun".
func turnProvider() string {
	switch p := strings.ToLower(strings.TrimSpace(os.Getenv("ASEMAN_TURN_PROVIDER"))); p {
	case "cloudflare", "coturn", "stun":
		return p
	}
	if os.Getenv("ASEMAN_TURN_CF_KEY_ID") != "" && os.Getenv("ASEMAN_TURN_CF_API_TOKEN") != "" {
		return "cloudflare"
	}
	if os.Getenv("ASEMAN_TURN_URLS") != "" && os.Getenv("ASEMAN_TURN_SECRET") != "" {
		return "coturn"
	}
	return "stun"
}

// iceServers are the servers a call's two phones use. A relay that cannot be
// reached is not an error: the call goes on with STUN alone.
func (s *Service) iceServers(ctx context.Context) []ICEServer {
	ttl := turnTTL()
	var servers []ICEServer
	var err error
	switch turnProvider() {
	case "cloudflare":
		servers, err = cloudflareICE(ctx, strings.TrimSpace(os.Getenv("ASEMAN_TURN_CF_KEY_ID")), strings.TrimSpace(os.Getenv("ASEMAN_TURN_CF_API_TOKEN")), ttl)
	case "coturn":
		servers = coturnICE(strings.Split(os.Getenv("ASEMAN_TURN_URLS"), ","), strings.TrimSpace(os.Getenv("ASEMAN_TURN_SECRET")), ttl, time.Now())
	}
	if err != nil && s.L != nil {
		s.L.Warn("turn credentials not issued", "provider", turnProvider(), "error", err)
	}
	return append(servers, stunOnly)
}

// coturnICE are TURN credentials in coturn's REST scheme: the username is the
// expiry time, the password an HMAC of it under the shared secret.
func coturnICE(urls []string, secret string, ttl time.Duration, now time.Time) []ICEServer {
	var list []string
	for _, u := range urls {
		if u = strings.TrimSpace(u); u != "" {
			list = append(list, u)
		}
	}
	if len(list) == 0 || secret == "" {
		return nil
	}
	user := strconv.FormatInt(now.Add(ttl).Unix(), 10)
	mac := hmac.New(sha1.New, []byte(secret))
	mac.Write([]byte(user))
	return []ICEServer{{URLs: list, Username: user, Credential: base64.StdEncoding.EncodeToString(mac.Sum(nil))}}
}

// cloudflareICE asks Cloudflare Realtime for short-lived TURN credentials.
func cloudflareICE(ctx context.Context, keyID, token string, ttl time.Duration) ([]ICEServer, error) {
	if keyID == "" || token == "" {
		return nil, fmt.Errorf("cloudflare turn key is not configured")
	}
	body, _ := json.Marshal(map[string]any{"ttl": int(ttl.Seconds())})
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, cloudflareAPI+"/v1/turn/keys/"+keyID+"/credentials/generate-ice-servers", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode/100 != 2 {
		return nil, fmt.Errorf("cloudflare answered %d", res.StatusCode)
	}
	// The answer is a list of servers (newer) or one server (older).
	var out struct {
		ICEServers json.RawMessage `json:"iceServers"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	var many []ICEServer
	if err := json.Unmarshal(out.ICEServers, &many); err == nil && len(many) > 0 {
		return many, nil
	}
	var one ICEServer
	if err := json.Unmarshal(out.ICEServers, &one); err != nil || len(one.URLs) == 0 {
		return nil, fmt.Errorf("cloudflare answered no servers")
	}
	return []ICEServer{one}, nil
}
