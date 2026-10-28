package responsibilities

import (
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	rm "github.com/aseman/aseman/plugins/actions/responsibilities/models"
	"github.com/aseman/aseman/plugins/adapters/network/ports"
)

// Each service's hook: its signature scheme, checked with the
// responsibility's secret, and what of its event the agent is told. A hook
// returns the event's source and text ("" when the delivery matched no
// filter), whether the signature held, and, for the services that wait for
// one, a body to answer with.

// hookURL is a responsibility's public address.
func hookURL(id string) string {
	base := strings.TrimRight(strings.TrimSpace(os.Getenv("ASEMAN_PUBLIC_URL")), "/")
	if base == "" {
		base = "http://localhost:8080"
	}
	return base + HookPath + "/" + id
}

func hmacBase64(key []byte, parts ...[]byte) string {
	mac := hmac.New(sha256.New, key)
	for _, p := range parts {
		mac.Write(p)
	}
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func equal(a, b string) bool { return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1 }

// kept reports a delivery the filters let through.
func kept(r *rm.Responsibility, kind, action, text string) bool {
	if len(r.Events) > 0 && !contains(r.Events, kind) {
		return false
	}
	if r.Action != "" && !strings.EqualFold(r.Action, action) {
		return false
	}
	return matches(r, text)
}

// gitlab checks X-Gitlab-Token (GitLab sends the secret itself) and matches
// the project, event and action.
func (s *Service) gitlab(r *rm.Responsibility, secret string, req *network.Request) (string, string, bool) {
	if !equal(header(req.Header, "X-Gitlab-Token"), secret) {
		return "", "", false
	}
	kind := header(req.Header, "X-Gitlab-Event")
	var p struct {
		Project struct {
			Path string `json:"path_with_namespace"`
		} `json:"project"`
		User struct {
			Username string `json:"username"`
		} `json:"user"`
		Attrs struct {
			Action      string `json:"action"`
			Title       string `json:"title"`
			Description string `json:"description"`
			Note        string `json:"note"`
			URL         string `json:"url"`
			Status      string `json:"status"`
			Ref         string `json:"ref"`
		} `json:"object_attributes"`
		Ref     string `json:"ref"`
		Commits []struct {
			Message string `json:"message"`
		} `json:"commits"`
	}
	_ = json.Unmarshal(req.Body, &p)
	if r.Repo != "" && !strings.EqualFold(r.Repo, p.Project.Path) {
		return "", "", true
	}
	var b strings.Builder
	fmt.Fprintf(&b, "GitLab %s %s in %s by %s\n", kind, p.Attrs.Action, p.Project.Path, p.User.Username)
	if p.Attrs.Title != "" {
		fmt.Fprintf(&b, "%s\n%s\n%s\n", p.Attrs.Title, p.Attrs.URL, p.Attrs.Description)
	}
	if p.Attrs.Note != "" {
		b.WriteString("Comment: " + p.Attrs.Note + "\n")
	}
	if p.Attrs.Status != "" {
		fmt.Fprintf(&b, "Pipeline %s on %s\n", p.Attrs.Status, p.Attrs.Ref)
	}
	for _, c := range p.Commits {
		b.WriteString("- " + strings.SplitN(c.Message, "\n", 2)[0] + "\n")
	}
	if !kept(r, kind, p.Attrs.Action, b.String()) {
		return "", "", true
	}
	return "gitlab " + p.Project.Path, b.String(), true
}

// teams checks an outgoing webhook's HMAC (the token is base64) and takes
// the message. Teams waits for an answer.
func (s *Service) teams(r *rm.Responsibility, secret string, req *network.Request) (string, string, bool) {
	key, err := base64.StdEncoding.DecodeString(secret)
	if err != nil {
		return "", "", false
	}
	if !equal(strings.TrimPrefix(header(req.Header, "Authorization"), "HMAC "), hmacBase64(key, req.Body)) {
		return "", "", false
	}
	var p struct {
		Text string `json:"text"`
		From struct {
			Name string `json:"name"`
		} `json:"from"`
		Conversation struct {
			ID string `json:"id"`
		} `json:"conversation"`
	}
	_ = json.Unmarshal(req.Body, &p)
	text := strings.TrimSpace(tags.ReplaceAllString(p.Text, ""))
	if (r.Channel != "" && r.Channel != p.Conversation.ID) || !matches(r, text) {
		return "", "", true
	}
	return "teams message from " + p.From.Name, fmt.Sprintf("Microsoft Teams message from %s:\n%s", p.From.Name, text), true
}

// sms checks Twilio's X-Twilio-Signature over the public URL and the form.
func (s *Service) sms(r *rm.Responsibility, secret string, req *network.Request) (string, string, bool) {
	form, err := url.ParseQuery(string(req.Body))
	if err != nil {
		return "", "", false
	}
	keys := make([]string, 0, len(form))
	for k := range form {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString(hookURL(r.ID.String()))
	for _, k := range keys {
		b.WriteString(k + form.Get(k))
	}
	mac := hmac.New(sha1.New, []byte(secret))
	mac.Write([]byte(b.String()))
	if !equal(header(req.Header, "X-Twilio-Signature"), base64.StdEncoding.EncodeToString(mac.Sum(nil))) {
		return "", "", false
	}
	from, body := form.Get("From"), form.Get("Body")
	if (r.From != "" && r.From != from) || !matches(r, body) {
		return "", "", true
	}
	return "text message from " + from, fmt.Sprintf("Text message from %s:\n%s", from, body), true
}

// stripe checks Stripe-Signature (t=…,v1=…) within the replay window.
func (s *Service) stripe(r *rm.Responsibility, secret string, req *network.Request) (string, string, bool) {
	var ts string
	var sigs []string
	for _, part := range strings.Split(header(req.Header, "Stripe-Signature"), ",") {
		k, v, _ := strings.Cut(strings.TrimSpace(part), "=")
		switch k {
		case "t":
			ts = v
		case "v1":
			sigs = append(sigs, v)
		}
	}
	sec, err := strconv.ParseInt(ts, 10, 64)
	if err != nil || absDuration(s.now().Sub(time.Unix(sec, 0))) > replayWindow {
		return "", "", false
	}
	want := hmacHex(secret, []byte(ts+"."), req.Body)
	ok := false
	for _, sig := range sigs {
		ok = ok || equal(sig, want)
	}
	if !ok {
		return "", "", false
	}
	var p struct {
		Type string `json:"type"`
		Data struct {
			Object map[string]any `json:"object"`
		} `json:"data"`
	}
	_ = json.Unmarshal(req.Body, &p)
	obj := p.Data.Object
	var b strings.Builder
	fmt.Fprintf(&b, "Stripe %s\n", p.Type)
	for _, k := range []string{"id", "amount", "amount_due", "currency", "status", "customer", "customer_email", "description", "reason", "billing_reason"} {
		if v, ok := obj[k]; ok && v != nil && fmt.Sprint(v) != "" {
			fmt.Fprintf(&b, "%s: %v\n", k, v)
		}
	}
	if !kept(r, p.Type, "", b.String()) {
		return "", "", true
	}
	return "stripe", b.String(), true
}

// linear checks Linear-Signature and the delivery's own timestamp.
func (s *Service) linear(r *rm.Responsibility, secret string, req *network.Request) (string, string, bool) {
	if !equal(header(req.Header, "Linear-Signature"), hmacHex(secret, req.Body)) {
		return "", "", false
	}
	var p struct {
		Action    string `json:"action"`
		Type      string `json:"type"`
		URL       string `json:"url"`
		Timestamp int64  `json:"webhookTimestamp"`
		Data      struct {
			Identifier  string `json:"identifier"`
			Title       string `json:"title"`
			Description string `json:"description"`
			Body        string `json:"body"`
		} `json:"data"`
	}
	_ = json.Unmarshal(req.Body, &p)
	if absDuration(s.now().Sub(time.UnixMilli(p.Timestamp))) > replayWindow {
		return "", "", false
	}
	d := p.Data
	text := fmt.Sprintf("Linear %s %s %s %s\n%s\n%s%s", p.Type, p.Action, d.Identifier, d.Title, p.URL, d.Description, d.Body)
	if !kept(r, p.Type, p.Action, text) {
		return "", "", true
	}
	return "linear", text, true
}

// jira checks X-Hub-Signature (sha256=…) and matches the project.
func (s *Service) jira(r *rm.Responsibility, secret string, req *network.Request) (string, string, bool) {
	if !equal(strings.TrimPrefix(header(req.Header, "X-Hub-Signature"), "sha256="), hmacHex(secret, req.Body)) {
		return "", "", false
	}
	var p struct {
		Event string `json:"webhookEvent"`
		User  struct {
			Name string `json:"displayName"`
		} `json:"user"`
		Issue struct {
			Key    string `json:"key"`
			Fields struct {
				Summary     string `json:"summary"`
				Description any    `json:"description"`
				Project     struct {
					Key string `json:"key"`
				} `json:"project"`
				Status struct {
					Name string `json:"name"`
				} `json:"status"`
			} `json:"fields"`
		} `json:"issue"`
		Comment struct {
			Body any `json:"body"`
		} `json:"comment"`
	}
	_ = json.Unmarshal(req.Body, &p)
	if r.Repo != "" && !strings.EqualFold(r.Repo, p.Issue.Fields.Project.Key) {
		return "", "", true
	}
	text := fmt.Sprintf("Jira %s by %s: %s %s (%s)\n", p.Event, p.User.Name, p.Issue.Key, p.Issue.Fields.Summary, p.Issue.Fields.Status.Name)
	if d, ok := p.Issue.Fields.Description.(string); ok && d != "" {
		text += d + "\n"
	}
	if c, ok := p.Comment.Body.(string); ok && c != "" {
		text += "Comment: " + c + "\n"
	}
	if !kept(r, p.Event, "", text) {
		return "", "", true
	}
	return "jira " + p.Issue.Fields.Project.Key, text, true
}

// shopify checks X-Shopify-Hmac-Sha256 and matches the topic.
func (s *Service) shopify(r *rm.Responsibility, secret string, req *network.Request) (string, string, bool) {
	if !equal(header(req.Header, "X-Shopify-Hmac-Sha256"), hmacBase64([]byte(secret), req.Body)) {
		return "", "", false
	}
	topic := header(req.Header, "X-Shopify-Topic")
	var obj map[string]any
	_ = json.Unmarshal(req.Body, &obj)
	var b strings.Builder
	fmt.Fprintf(&b, "Shopify %s from %s\n", topic, header(req.Header, "X-Shopify-Shop-Domain"))
	for _, k := range []string{"name", "id", "email", "total_price", "currency", "financial_status", "fulfillment_status", "title", "note"} {
		if v, ok := obj[k]; ok && v != nil && fmt.Sprint(v) != "" {
			fmt.Fprintf(&b, "%s: %v\n", k, v)
		}
	}
	if !kept(r, topic, "", b.String()) {
		return "", "", true
	}
	return "shopify", b.String(), true
}
