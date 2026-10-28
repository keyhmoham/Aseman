package channels

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/aseman/aseman/internal/plugins/entity"
	"github.com/aseman/aseman/internal/plugins/identity"
	"github.com/aseman/aseman/pkg/errs"
	"github.com/aseman/aseman/pkg/replies"
	cm "github.com/aseman/aseman/plugins/actions/channels/models"
	"github.com/aseman/aseman/plugins/actions/governance/models/gate"
	"github.com/aseman/aseman/plugins/adapters/database/ports"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// Text messages, through Twilio: messages arrive at TwilioSMSPath (form
// posts signed with X-Twilio-Signature), answers go out with the Messages
// API. An approval is asked with a four-digit code: YES, ALWAYS or NO
// followed by it.
const TwilioSMSPath = "/channels/v1/twilio/sms"

// twilioURL is the address Twilio signs: the public one it posts to.
func twilioURL() string {
	public := strings.TrimRight(strings.TrimSpace(os.Getenv("ASEMAN_PUBLIC_URL")), "/")
	if public == "" {
		public = "http://localhost:8080"
	}
	return public + TwilioSMSPath
}

// twilioSignature is Twilio's: HMAC-SHA1 of the URL and the sorted form
// fields, base64.
func twilioSignature(token, fullURL string, form url.Values) string {
	keys := make([]string, 0, len(form))
	for k := range form {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString(fullURL)
	for _, k := range keys {
		b.WriteString(k + form.Get(k))
	}
	mac := hmac.New(sha1.New, []byte(token))
	mac.Write([]byte(b.String()))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func twiml(text string) *network.Response {
	body := `<?xml version="1.0" encoding="UTF-8"?><Response>`
	if text != "" {
		body += "<Message>" + xmlEscape(text) + "</Message>"
	}
	body += "</Response>"
	return &network.Response{Status: http.StatusOK, Header: map[string]string{"Content-Type": "text/xml"}, Body: []byte(body)}
}

func xmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;").Replace(s)
}

func (s *Service) serveSMS(ctx context.Context, req *network.Request) (*network.Response, error) {
	st, err := s.settings(ctx, cm.Twilio)
	if err != nil || !st.Enabled {
		return jsonReply(http.StatusNotFound, map[string]string{"error": "sms is not set up"}), nil
	}
	form, err := url.ParseQuery(string(req.Body))
	if err != nil || !hmac.Equal([]byte(twilioSignature(st.token, twilioURL(), form)), []byte(headerOf(req.Header, "X-Twilio-Signature"))) {
		return jsonReply(http.StatusUnauthorized, map[string]string{"error": "signature"}), nil
	}
	from, text := form.Get("From"), strings.TrimSpace(form.Get("Body"))
	if code, ok := linkCommand(text); ok {
		return twiml(s.redeem(ctx, cm.Twilio, code, cm.Binding{External: from})), nil
	}
	b, ok := s.binding(ctx, cm.Twilio, "", from)
	if !ok {
		return twiml("This number is not linked to Aseman. In Aseman, open Settings → Channels → Text messages, then text: link <code>"), nil
	}
	if reply, handled := s.smsAnswer(ctx, b, text); handled {
		return twiml(reply), nil
	}
	s.converse(ctx, b, text, func(ctx context.Context, answer string) {
		body, chips := replies.Parse(answer)
		if len(chips) > 0 {
			body += "\n\nReply: " + strings.Join(chips, " / ")
		}
		if err := s.smsSend(ctx, b.External, body); err != nil {
			s.L.Warn("sms reply not sent", "error", err)
		}
	})
	return twiml(""), nil
}

// smsAnswer reads "YES 4821", "ALWAYS 4821" or "NO 4821".
func (s *Service) smsAnswer(ctx context.Context, b *cm.Binding, text string) (string, bool) {
	f := strings.Fields(strings.ToUpper(text))
	if len(f) != 2 || len(f[1]) != 4 {
		return "", false
	}
	answer := map[string]string{"YES": "once", "ALWAYS": "always", "NO": "refuse"}[f[0]]
	if answer == "" {
		return "", false
	}
	var rows []cm.SMSPrompt
	if err := s.R.List(ctx, "channel_sms_prompts", database.Filter{Equal: map[string]any{"account_id": b.AccountID, "code": f[1]}, Limit: 1}, &rows); err != nil || len(rows) == 0 {
		return "No approval waits on that code.", true
	}
	p := rows[0]
	_ = s.R.Delete(ctx, "channel_sms_prompts", p.ID)
	if !s.now().Before(p.ExpiresAt) {
		return "That approval expired.", true
	}
	caller, _ := parseID(b.AccountID)
	if err := s.Governance.Answer(ctx, caller, p.ApprovalID, answer); err != nil {
		return "Couldn't answer: " + err.Error(), true
	}
	return answerWord(answer) + ".", true
}

func (s *Service) smsApproval(ctx context.Context, b *cm.Binding, note gate.ApprovalNote) error {
	n, err := rand.Int(rand.Reader, big.NewInt(9000))
	if err != nil {
		return err
	}
	code := fmt.Sprintf("%04d", 1000+n.Int64())
	id, err := identity.New(s.K.NodeID())
	if err != nil {
		return err
	}
	now := s.now().UTC()
	p := &cm.SMSPrompt{Entity: entity.Entity{ID: id, CreatedAt: now, UpdatedAt: now}, AccountID: b.AccountID, Phone: b.External,
		Code: code, ApprovalID: note.ID, ExpiresAt: now.Add(30 * time.Minute)}
	if err := s.R.CreateID(ctx, "channel_sms_prompts", id, p); err != nil {
		return err
	}
	return s.smsSend(ctx, b.External, "Aseman: "+clip(note.Summary, 300)+"\nReply YES "+code+", ALWAYS "+code+" or NO "+code)
}

// smsSend texts a number from the node's Twilio number.
func (s *Service) smsSend(ctx context.Context, to, text string) error {
	st, err := s.settings(ctx, cm.Twilio)
	if err != nil {
		return err
	}
	form := url.Values{"From": {st.From}, "To": {to}, "Body": {clip(text, 1500)}}
	endpoint := s.TwilioAPI + "/Accounts/" + url.PathEscape(st.AppID) + "/Messages.json"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.SetBasicAuth(st.AppID, st.token)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := s.HTTP.Do(req)
	if err != nil {
		return errs.Wrap(errs.CodeUnavailable, err, "twilio")
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return errs.New(errs.CodeUnavailable, "twilio: "+resp.Status)
	}
	return nil
}

func parseID(v string) (identity.ID, error) { return identity.Parse(v) }
