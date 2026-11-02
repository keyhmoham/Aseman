package users

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

// Push notifications for the Android app, sent to Firebase Cloud Messaging (FCM, the HTTP v1 API) with
// the node's own service account. The iOS side is in push.go; a device's platform says which one is used.
//
// The node needs a service-account key from the Firebase project the app's google-services.json came from
// (Firebase console → Project settings → Service accounts → Generate new private key):
//
//	ASEMAN_FCM_SERVICE_ACCOUNT  the key's .json: its text, a path to the file, or the file base64-encoded
//	                               (one line, easy to put in .env)
//
// Without it nothing is sent to Android and everything else works as before.

// fcmChannel is the notification channel the app creates for what the node sends (Android 8+ needs one).
const fcmChannel = "messages"

const fcmScope = "https://www.googleapis.com/auth/firebase.messaging"

type fcmAccount struct {
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

type fcmClient struct {
	account *fcmAccount
	key     *rsa.PrivateKey
	http    *http.Client

	mu      sync.Mutex
	access  string
	expires time.Time
}

var (
	fcmOnce sync.Once
	fcmOne  *fcmClient
)

// fcm is the node's connection to Firebase, built once from the environment.
func fcm() *fcmClient {
	fcmOnce.Do(func() {
		c := &fcmClient{http: &http.Client{Timeout: 15 * time.Second}}
		if account, key, err := parseFCMAccount(os.Getenv("ASEMAN_FCM_SERVICE_ACCOUNT")); err == nil {
			c.account, c.key = account, key
		}
		fcmOne = c
	})
	return fcmOne
}

func (c *fcmClient) configured() bool {
	return c != nil && c.account != nil && c.key != nil && c.account.ProjectID != "" && c.account.ClientEmail != ""
}

// parseFCMAccount reads the service-account key however it was given: the JSON itself, a path to the file,
// or the file in base64.
func parseFCMAccount(raw string) (*fcmAccount, *rsa.PrivateKey, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil, errors.New("no key")
	}
	text := raw
	if !strings.HasPrefix(text, "{") {
		if b, err := os.ReadFile(raw); err == nil {
			text = string(b)
		} else if b, err := base64.StdEncoding.DecodeString(raw); err == nil {
			text = string(b)
		}
	}
	var account fcmAccount
	if err := json.Unmarshal([]byte(text), &account); err != nil {
		return nil, nil, errors.New("the FCM service account is not a key file")
	}
	block, _ := pem.Decode([]byte(account.PrivateKey))
	if block == nil {
		return nil, nil, errors.New("the FCM service account has no private key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, nil, err
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, nil, errors.New("the FCM private key is not an RSA key")
	}
	if account.TokenURI == "" {
		account.TokenURI = "https://oauth2.googleapis.com/token"
	}
	return &account, key, nil
}

// signRS256 makes a compact JWT signed with an RSA key.
func signRS256(key *rsa.PrivateKey, header, claims map[string]any) (string, error) {
	enc := func(v any) (string, error) {
		b, err := json.Marshal(v)
		return base64.RawURLEncoding.EncodeToString(b), err
	}
	h, err := enc(header)
	if err != nil {
		return "", err
	}
	p, err := enc(claims)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256([]byte(h + "." + p))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		return "", err
	}
	return h + "." + p + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

// accessToken is what Google accepts for an hour in exchange for the signed statement of who the node is;
// a new one is fetched a few minutes before it runs out.
func (c *fcmClient) accessToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.access != "" && time.Until(c.expires) > 5*time.Minute {
		return c.access, nil
	}
	now := time.Now()
	assertion, err := signRS256(c.key, map[string]any{"alg": "RS256", "typ": "JWT"}, map[string]any{
		"iss": c.account.ClientEmail, "scope": fcmScope, "aud": c.account.TokenURI, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix(),
	})
	if err != nil {
		return "", err
	}
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {assertion}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.account.TokenURI, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := c.http.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 16<<10))
	var answer struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
		Error       string `json:"error"`
	}
	_ = json.Unmarshal(raw, &answer)
	if res.StatusCode != http.StatusOK || answer.AccessToken == "" {
		return "", fmt.Errorf("fcm: no access token (%d %s)", res.StatusCode, answer.Error)
	}
	c.access, c.expires = answer.AccessToken, now.Add(time.Duration(answer.ExpiresIn)*time.Second)
	return c.access, nil
}

// fcmPayload is the notification as Firebase wants it. What the app needs to open the right screen goes in
// the data map (strings only), which is where the app's notification library reads it.
func fcmPayload(device string, note PushNote) ([]byte, error) {
	data := map[string]string{"kind": note.Kind}
	for k, v := range map[string]string{"space": note.Space, "room": note.Room, "peer": note.Peer} {
		if v != "" {
			data[k] = v
		}
	}
	android := map[string]any{
		"priority":     "HIGH",
		"notification": map[string]any{"channel_id": fcmChannel},
	}
	if note.Collapse != "" {
		collapse := note.Collapse
		if len(collapse) > 64 {
			collapse = collapse[:64]
		}
		android["collapse_key"] = collapse
		// The same tag replaces an earlier notification on screen instead of stacking under it.
		android["notification"] = map[string]any{"channel_id": fcmChannel, "tag": collapse}
	}
	return json.Marshal(map[string]any{"message": map[string]any{
		"token":        device,
		"notification": map[string]any{"title": note.Title, "body": note.Body},
		"data":         data,
		"android":      android,
	}})
}

// fcmGone reports whether Firebase's answer says the token is dead (the app was removed or re-installed).
func fcmGone(status int, body []byte) bool {
	var answer struct {
		Error struct {
			Status  string `json:"status"`
			Details []struct {
				ErrorCode string `json:"errorCode"`
			} `json:"details"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &answer)
	if status == http.StatusNotFound || answer.Error.Status == "NOT_FOUND" || answer.Error.Status == "UNREGISTERED" {
		return true
	}
	for _, d := range answer.Error.Details {
		if d.ErrorCode == "UNREGISTERED" {
			return true
		}
	}
	return false
}

// send delivers one notification to one device, and reports whether the token is dead.
func (c *fcmClient) send(ctx context.Context, device string, note PushNote) (gone bool, err error) {
	body, err := fcmPayload(device, note)
	if err != nil {
		return false, err
	}
	access, err := c.accessToken(ctx)
	if err != nil {
		return false, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://fcm.googleapis.com/v1/projects/"+c.account.ProjectID+"/messages:send", bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Content-Type", "application/json")
	res, err := c.http.Do(req)
	if err != nil {
		return false, err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 8<<10))
	switch {
	case res.StatusCode == http.StatusOK:
		return false, nil
	case fcmGone(res.StatusCode, raw):
		return true, nil
	case res.StatusCode == http.StatusUnauthorized:
		// The cached access token was refused: fetch a new one next time.
		c.mu.Lock()
		c.access = ""
		c.mu.Unlock()
	}
	return false, fmt.Errorf("fcm: %d %s", res.StatusCode, strings.TrimSpace(string(raw)))
}
