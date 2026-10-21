package users

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/plugins/actions/support/helper"
	"github.com/aseman/aseman/plugins/actions/support/repo"
	database "github.com/aseman/aseman/plugins/adapters/database/ports"
)

// Push notifications for the iOS app, sent straight to Apple (APNs) with the
// node's own key. A device registers its token when a person signs in on it
// and removes it when they sign out; the rest of the node calls Push with the
// people to tell and what to say.
//
// The node needs an APNs auth key from the Apple developer account:
//
//	ASEMAN_APNS_KEY      the .p8 key: its text, a path to the file, or the
//	                        file base64-encoded (one line, easy to put in .env)
//	ASEMAN_APNS_KEY_ID   the key's 10-character id
//	ASEMAN_APNS_TEAM_ID  the developer team id
//	ASEMAN_APNS_TOPIC    the app's bundle id (defaults to the first id in
//	                        ASEMAN_APPLE_CLIENT_ID, which is the same thing)
//
// Without them nothing is sent and everything else works as before.

// PushDevice is one phone a person is signed in on.
type PushDevice struct {
	ID       string `db:"id" json:"id"` // sha256 of the token: one row per device, whoever is signed in
	Account  string `db:"account" json:"account"`
	Token    string `db:"token" json:"-"`
	Platform string `db:"platform" json:"platform"`
	// Environment is which of Apple's two services issued the token:
	// "production" (TestFlight, App Store) or "development" (a build run from Xcode).
	Environment string    `db:"environment" json:"environment"`
	UpdatedAt   time.Time `db:"updated_at" json:"updated_at"`
}

// PushNote is what a notification says and where tapping it leads.
type PushNote struct {
	Title string `json:"title"`
	Body  string `json:"body"`
	// Kind is what happened: "message" or "invite". With Space and Room it is
	// what the app needs to open the right screen.
	Kind  string `json:"kind"`
	Space string `json:"space,omitempty"`
	Room  string `json:"room,omitempty"`
	// Collapse replaces an earlier notification with the same value instead of
	// stacking under it.
	Collapse string `json:"collapse,omitempty"`
}

func pushActions(s *Service) []api.Action {
	return []api.Action{
		helper.Action{Namespace: "users", Name: "push_register", Summary: "Register this device for push notifications", Handler: s.pushRegister},
		helper.Action{Namespace: "users", Name: "push_unregister", Summary: "Stop push notifications to this device", Handler: s.pushUnregister},
	}
}

func deviceID(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func (s *Service) deviceKey(token string) (identity.ID, error) {
	// A stable id per token within this node, so registering again replaces the row.
	return identity.Parse(s.K.NodeID().String() + repo.ExecutionKey("push/" + deviceID(token))[16:])
}

func (s *Service) pushRegister(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Token       string `json:"token"`
		Platform    string `json:"platform"`
		Environment string `json:"environment"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	in.Token = strings.TrimSpace(in.Token)
	if in.Token == "" || len(in.Token) > 512 {
		return nil, errs.InvalidArgument("device token required")
	}
	if in.Platform != "ios" {
		return nil, errs.InvalidArgument("only ios devices can be registered")
	}
	if in.Environment != "development" {
		in.Environment = "production"
	}
	key, err := s.deviceKey(in.Token)
	if err != nil {
		return nil, err
	}
	// The device now belongs to whoever just signed in on it: someone who
	// signed out without the network must not keep getting the next person's news.
	row := &PushDevice{ID: key.String(), Account: req.Caller.ID.String(), Token: in.Token, Platform: in.Platform, Environment: in.Environment, UpdatedAt: time.Now().UTC()}
	if err = s.R.CreateID(ctx, "push_devices", key, row); errs.CodeOf(err) == errs.CodeAlreadyExists {
		err = s.R.Update(ctx, "push_devices", key, row)
	}
	if err != nil {
		return nil, err
	}
	return helper.JSON(map[string]any{"ok": true, "enabled": apns().configured()})
}

func (s *Service) pushUnregister(ctx context.Context, req *api.ActionRequest) (*api.ActionResponse, error) {
	if err := helper.RequireUser(req); err != nil {
		return nil, err
	}
	var in struct {
		Token string `json:"token"`
	}
	if err := helper.Decode(req, &in); err != nil {
		return nil, err
	}
	key, err := s.deviceKey(strings.TrimSpace(in.Token))
	if err != nil {
		return nil, err
	}
	var row PushDevice
	// Only the person signed in on the device removes it.
	if s.R.Get(ctx, "push_devices", key, &row) == nil && row.Account == req.Caller.ID.String() {
		_ = s.R.Delete(ctx, "push_devices", key)
	}
	return helper.JSON(map[string]any{"ok": true})
}

// Push tells each of the given people, on every device they are signed in on,
// and keeps the notification in their in-app inbox.
// It never fails its caller: a notification is a courtesy on top of the thing
// that happened, which has already been stored.
func (s *Service) Push(ctx context.Context, to []identity.ID, note PushNote) {
	for _, account := range to {
		s.keep(ctx, account, note)
	}
	client := apns()
	if !client.configured() || len(to) == 0 {
		return
	}
	for _, account := range to {
		var devices []PushDevice
		if err := s.R.List(ctx, "push_devices", database.Filter{Equal: map[string]any{"account": account.String()}}, &devices); err != nil {
			continue
		}
		for i := range devices {
			d := devices[i]
			gone, env, err := client.send(ctx, d.Token, d.Environment, note)
			switch {
			case gone:
				// Apple says the token is dead (the app was removed, or re-installed).
				if key, e := identity.Parse(d.ID); e == nil {
					_ = s.R.Delete(ctx, "push_devices", key)
				}
			case err != nil:
				if s.L != nil {
					s.L.Warn("push not delivered", "account", account.String(), "error", err)
				}
			case env != d.Environment:
				// The token belongs to Apple's other service: remember, so the
				// next one goes there first.
				d.Environment = env
				if key, e := identity.Parse(d.ID); e == nil {
					_ = s.R.Update(ctx, "push_devices", key, &d)
				}
			}
		}
	}
}

// ── APNs ────────────────────────────────────────────────────────────────────

type apnsClient struct {
	keyID, teamID, topic string
	key                  *ecdsa.PrivateKey
	http                 *http.Client

	mu     sync.Mutex
	bearer string
	signed time.Time
}

var (
	apnsOnce sync.Once
	apnsOne  *apnsClient
)

// apns is the node's connection to Apple, built once from the environment.
func apns() *apnsClient {
	apnsOnce.Do(func() {
		c := &apnsClient{
			keyID:  strings.TrimSpace(os.Getenv("ASEMAN_APNS_KEY_ID")),
			teamID: strings.TrimSpace(os.Getenv("ASEMAN_APNS_TEAM_ID")),
			topic:  strings.TrimSpace(os.Getenv("ASEMAN_APNS_TOPIC")),
			// APNs speaks HTTP/2 only.
			http: &http.Client{Timeout: 15 * time.Second, Transport: &http.Transport{ForceAttemptHTTP2: true, MaxIdleConns: 4, IdleConnTimeout: 5 * time.Minute}},
		}
		if c.topic == "" {
			c.topic = strings.TrimSpace(strings.Split(os.Getenv("ASEMAN_APPLE_CLIENT_ID"), ",")[0])
		}
		c.key, _ = parseAPNsKey(os.Getenv("ASEMAN_APNS_KEY"))
		apnsOne = c
	})
	return apnsOne
}

func (c *apnsClient) configured() bool {
	return c != nil && c.key != nil && c.keyID != "" && c.teamID != "" && c.topic != ""
}

// parseAPNsKey reads the .p8 key however it was given: the PEM text itself
// (newlines may be written as \n), a path to the file, or the file in base64.
func parseAPNsKey(raw string) (*ecdsa.PrivateKey, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, errors.New("no key")
	}
	text := strings.ReplaceAll(raw, `\n`, "\n")
	if !strings.Contains(text, "BEGIN") {
		if b, err := os.ReadFile(raw); err == nil {
			text = string(b)
		} else if b, err := base64.StdEncoding.DecodeString(raw); err == nil {
			text = string(b)
		}
	}
	block, _ := pem.Decode([]byte(text))
	if block == nil {
		return nil, errors.New("the APNs key is not a .p8 key")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("the APNs key is not an EC key")
	}
	return key, nil
}

// token is the signed statement of who the node is, which Apple accepts for an
// hour; a new one is made well before that.
func (c *apnsClient) token() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.bearer != "" && time.Since(c.signed) < 40*time.Minute {
		return c.bearer, nil
	}
	now := time.Now()
	signed, err := signES256(c.key, map[string]any{"alg": "ES256", "kid": c.keyID}, map[string]any{"iss": c.teamID, "iat": now.Unix()})
	if err != nil {
		return "", err
	}
	c.bearer, c.signed = signed, now
	return signed, nil
}

// signES256 makes a compact JWT signed with an EC P-256 key.
func signES256(key *ecdsa.PrivateKey, header, claims map[string]any) (string, error) {
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
	r, sgn, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		return "", err
	}
	// The signature is r and s side by side, each padded to the curve's size.
	size := (key.Curve.Params().BitSize + 7) / 8
	sig := make([]byte, 2*size)
	r.FillBytes(sig[:size])
	sgn.FillBytes(sig[size:])
	return h + "." + p + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

func apnsHost(environment string) string {
	if environment == "development" {
		return "https://api.sandbox.push.apple.com"
	}
	return "https://api.push.apple.com"
}

// apnsPayload is the notification as Apple wants it.
func apnsPayload(note PushNote) ([]byte, error) {
	aps := map[string]any{
		"alert": map[string]any{"title": note.Title, "body": note.Body},
		"sound": "default",
	}
	if note.Space != "" {
		// One stack per project in Notification Centre.
		aps["thread-id"] = note.Space
	}
	// What the app needs to open the right screen. It goes under "body": the
	// app's notification library hands the app that part of a remote
	// notification and nothing else.
	return json.Marshal(map[string]any{"aps": aps, "body": map[string]any{"kind": note.Kind, "space": note.Space, "room": note.Room}})
}

// send delivers one notification to one device. A token is issued by one of
// Apple's two services and is unknown to the other, and an app cannot always
// say which: when the first refuses it as a bad token, the other is tried.
// It reports whether the token is dead, and which service accepted it.
func (c *apnsClient) send(ctx context.Context, device, environment string, note PushNote) (gone bool, accepted string, err error) {
	body, err := apnsPayload(note)
	if err != nil {
		return false, environment, err
	}
	other := "development"
	if environment == "development" {
		other = "production"
	}
	for _, env := range []string{environment, other} {
		status, reason, e := c.post(ctx, apnsHost(env), device, body, note.Collapse)
		if e != nil {
			return false, environment, e
		}
		switch {
		case status == http.StatusOK:
			return false, env, nil
		case status == http.StatusGone || reason == "Unregistered":
			return true, environment, nil
		case reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic":
			err = fmt.Errorf("apns: %s", reason)
			continue // perhaps the other service knows it
		default:
			return false, environment, fmt.Errorf("apns: %d %s", status, reason)
		}
	}
	// Neither service knows the token: it is not one of this app's.
	return true, environment, err
}

func (c *apnsClient) post(ctx context.Context, host, device string, body []byte, collapse string) (int, string, error) {
	bearer, err := c.token()
	if err != nil {
		return 0, "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+device, bytes.NewReader(body))
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("Authorization", "bearer "+bearer)
	req.Header.Set("apns-topic", c.topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")
	if collapse != "" {
		if len(collapse) > 64 {
			collapse = collapse[:64]
		}
		req.Header.Set("apns-collapse-id", collapse)
	}
	res, err := c.http.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(res.Body, 4<<10))
	var answer struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(raw, &answer)
	return res.StatusCode, answer.Reason, nil
}
