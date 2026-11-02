// Package emailtpl is the one place the site's transactional emails are
// written: each email has a definition (what it is for and the values it can
// use), default wording, and an optional override an admin saves in settings.
// Render turns the wording and the values into a subject, a plain-text body and
// a light HTML page, so the admin can preview every email without sending it.
package emailtpl

import (
	"fmt"
	"html"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/aseman/aseman/pkg/errs"
)

// Content is the wording of one email. Body is paragraphs separated by blank
// lines; {{name}} inserts a value. A paragraph that is only {{code}} is shown
// as a code box, and a paragraph whose values are all empty is left out.
type Content struct {
	Subject string `json:"subject"`
	Heading string `json:"heading"`
	Body    string `json:"body"`
}

// Var is a value an email can use.
type Var struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	// Sample is what the preview shows.
	Sample string `json:"sample"`
}

// Definition describes one email.
type Definition struct {
	Key         string  `json:"key"`
	Name        string  `json:"name"`
	Description string  `json:"description"`
	Vars        []Var   `json:"vars"`
	Default     Content `json:"default"`
}

const (
	maxSubject = 150
	maxHeading = 150
	maxBody    = 5000
)

var codeVar = Var{Name: "code", Description: "The one-time code", Sample: "482 917"}
var minutesVar = Var{Name: "minutes", Description: "How long the code works, in minutes", Sample: "15"}

// Definitions lists every email, in display order.
func Definitions() []Definition {
	return []Definition{
		{
			Key: "verify_email", Name: "Verify your email", Description: "Sent when someone signs up, or asks for a new code, to confirm their address.",
			Vars: []Var{codeVar, minutesVar},
			Default: Content{
				Subject: "Your Aseman verification code",
				Heading: "Verify your email",
				Body:    "Enter this code to verify your email and activate your account.\n\n{{code}}\n\nThe code expires in {{minutes}} minutes. If you didn’t create a Aseman account, you can ignore this email.",
			},
		},
		{
			Key: "password_reset", Name: "Password reset", Description: "Sent when someone asks to reset their password.",
			Vars: []Var{codeVar, minutesVar},
			Default: Content{
				Subject: "Your Aseman password reset code",
				Heading: "Reset your password",
				Body:    "Use this code to choose a new password.\n\n{{code}}\n\nThe code expires in {{minutes}} minutes. If you didn’t ask to reset your password, you can ignore this email and your password stays the same.",
			},
		},
		{
			Key: "credit_granted", Name: "Credits added", Description: "Sent when you grant someone’s credit application.",
			Vars: []Var{
				{Name: "name", Description: "Their username", Sample: "ada"},
				{Name: "credits", Description: "How many credits were added", Sample: "500 credits"},
				{Name: "expiry_line", Description: "When the credits expire; empty if they never do", Sample: "These credits expire on 30 Nov 2026. Any part you haven’t used by then is taken back."},
				{Name: "note_line", Description: "The note you wrote in the decision; empty if none", Sample: "A note from the team:\nWelcome aboard, we’re excited to see what you build!"},
			},
			Default: Content{
				Subject: "Your Aseman credits have been added",
				Heading: "Your credits are ready",
				Body:    "Hi {{name}},\n\nWe added {{credits}} of complimentary credits to your Aseman wallet. They’re ready to use now.\n\n{{expiry_line}}\n\n{{note_line}}",
			},
		},
		{
			Key: "credit_declined", Name: "Credit application declined", Description: "Sent when you decline someone’s credit application.",
			Vars: []Var{
				{Name: "name", Description: "Their username", Sample: "ada"},
				{Name: "note_line", Description: "The note you wrote in the decision; empty if none", Sample: "A note from the team:\nTry again once you have a project underway."},
			},
			Default: Content{
				Subject: "About your Aseman credit application",
				Heading: "Thanks for applying",
				Body:    "Hi {{name}},\n\nThank you for applying. We can’t add complimentary credits to your wallet this time.\n\n{{note_line}}",
			},
		},
	}
}

// Find returns the definition of an email.
func Find(key string) (Definition, bool) {
	for _, d := range Definitions() {
		if d.Key == key {
			return d, true
		}
	}
	return Definition{}, false
}

var token = regexp.MustCompile(`\{\{\s*([a-z_]+)\s*\}\}`)

// Validate checks an override: required parts, sizes, and that it only uses
// values this email has.
func Validate(def Definition, c Content) error {
	c.Subject, c.Heading, c.Body = strings.TrimSpace(c.Subject), strings.TrimSpace(c.Heading), strings.TrimSpace(c.Body)
	if c.Subject == "" || c.Heading == "" || c.Body == "" {
		return errs.InvalidArgument("The subject, heading and body can’t be empty.")
	}
	if strings.ContainsAny(c.Subject, "\r\n") {
		return errs.InvalidArgument("The subject must be one line.")
	}
	if utf8.RuneCountInString(c.Subject) > maxSubject || utf8.RuneCountInString(c.Heading) > maxHeading || utf8.RuneCountInString(c.Body) > maxBody {
		return errs.InvalidArgument("That email is too long.")
	}
	known := map[string]bool{}
	for _, v := range def.Vars {
		known[v.Name] = true
	}
	for _, text := range []string{c.Subject, c.Heading, c.Body} {
		for _, m := range token.FindAllStringSubmatch(text, -1) {
			if !known[m[1]] {
				return errs.InvalidArgument(fmt.Sprintf("{{%s}} isn’t available in this email.", m[1]))
			}
		}
	}
	return nil
}

// Rendered is an email ready to send.
type Rendered struct {
	Subject string `json:"subject"`
	Text    string `json:"text"`
	HTML    string `json:"html"`
}

// Samples are the preview values of a definition.
func Samples(def Definition) map[string]string {
	out := map[string]string{}
	for _, v := range def.Vars {
		out[v.Name] = v.Sample
	}
	return out
}

func fill(text string, vars map[string]string) string {
	return token.ReplaceAllStringFunc(text, func(m string) string {
		return vars[token.FindStringSubmatch(m)[1]]
	})
}

// Render writes an email. content falls back to the definition's default for
// any empty part.
func Render(def Definition, content *Content, vars map[string]string) Rendered {
	c := def.Default
	if content != nil {
		if strings.TrimSpace(content.Subject) != "" {
			c.Subject = content.Subject
		}
		if strings.TrimSpace(content.Heading) != "" {
			c.Heading = content.Heading
		}
		if strings.TrimSpace(content.Body) != "" {
			c.Body = content.Body
		}
	}
	subject := strings.Join(strings.Fields(fill(c.Subject, vars)), " ")
	heading := strings.TrimSpace(fill(c.Heading, vars))

	type block struct {
		text string
		code bool
	}
	var blocks []block
	for _, raw := range strings.Split(strings.ReplaceAll(c.Body, "\r\n", "\n"), "\n\n") {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		text := strings.TrimSpace(fill(raw, vars))
		if text == "" {
			continue
		}
		blocks = append(blocks, block{text: text, code: strings.TrimSpace(raw) == "{{code}}"})
	}

	var plain, body strings.Builder
	plain.WriteString(heading + "\n\n")
	for _, b := range blocks {
		plain.WriteString(b.text + "\n\n")
		if b.code {
			fmt.Fprintf(&body, `<div style="margin:0 0 24px;padding:18px 20px;background:#F1F5F2;border:1px solid #E2E8E4;border-radius:12px;text-align:center;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:30px;line-height:1.2;font-weight:700;letter-spacing:6px;color:#12201A;">%s</div>`, html.EscapeString(b.text))
			continue
		}
		fmt.Fprintf(&body, `<p style="margin:0 0 16px;font-size:15px;line-height:1.65;color:#2B3A33;">%s</p>`, strings.ReplaceAll(html.EscapeString(b.text), "\n", "<br>"))
	}
	plain.WriteString("— Aseman")
	return Rendered{Subject: subject, Text: plain.String(), HTML: page(subject, heading, body.String())}
}

// page is the shared light layout every email sits in. Inline styles and
// tables only, so mail apps show it the same way.
func page(title, heading, body string) string {
	return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,600&display=swap" rel="stylesheet"><title>` + html.EscapeString(title) + `</title></head>
<body style="margin:0;padding:0;background:#F6F8F6;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F6F8F6;"><tr><td align="center" style="padding:40px 16px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;">
<tr><td style="padding:0 4px 20px;font-family:Fraunces,Georgia,'Times New Roman',serif;font-size:22px;font-weight:600;letter-spacing:-0.3px;color:#187A52;">Aseman</td></tr>
<tr><td style="background:#FFFFFF;border:1px solid #E2E8E4;border-radius:16px;padding:32px 28px;">
<h1 style="margin:0 0 18px;font-size:22px;line-height:1.3;font-weight:700;letter-spacing:-0.3px;color:#12201A;">` + html.EscapeString(heading) + `</h1>
` + body + `
</td></tr>
<tr><td style="padding:20px 4px 0;font-size:12px;line-height:1.6;color:#7A8A82;">You’re receiving this email because of activity on your Aseman account.<br>© Aseman</td></tr>
</table></td></tr></table></body></html>`
}
