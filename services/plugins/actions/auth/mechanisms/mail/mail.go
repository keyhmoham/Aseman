// Package mail delivers the auth namespace's transactional email (one-time
// codes). It supports the Resend API (via ASEMAN_RESEND_API_KEY) or standard
// SMTP. If neither is configured, messages are written to the node log so a
// development node stays usable without external services.
package mail

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/smtp"
	"os"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/logger"
)

// Environment variables configuring email delivery.
const (
	EnvResendKey = "ASEMAN_RESEND_API_KEY" // Resend API key (re_...)

	EnvHost     = "ASEMAN_SMTP_HOST" // host[:port], port defaults to 587
	EnvFrom     = "ASEMAN_SMTP_FROM" // sender address (e.g. noreply@yourdomain.com)
	EnvUser     = "ASEMAN_SMTP_USER"
	EnvPassword = "ASEMAN_SMTP_PASSWORD"
)

// Sender delivers one message.
type Sender interface {
	Send(ctx context.Context, to, subject, body string) error
	// Transport names the delivery mechanism ("resend", "smtp", or "log").
	Transport() string
}

// HTMLSender is a Sender that can also deliver an HTML version beside the text one.
type HTMLSender interface {
	Sender
	SendHTML(ctx context.Context, to, subject, text, html string) error
}

// Deliver sends a message with an HTML version when the sender supports it,
// else as plain text only.
func Deliver(ctx context.Context, s Sender, to, subject, text, html string) error {
	if h, ok := s.(HTMLSender); ok && html != "" {
		return h.SendHTML(ctx, to, subject, text, html)
	}
	return s.Send(ctx, to, subject, text)
}

// FromEnv returns the configured email sender:
// 1. Resend API sender if ASEMAN_RESEND_API_KEY is set.
// 2. SMTP sender if ASEMAN_SMTP_HOST is set.
// 3. Fallback log sender for local development.
func FromEnv(log *logger.Logger) Sender {
	from := strings.TrimSpace(os.Getenv(EnvFrom))
	if from == "" {
		from = "no-reply@localhost"
	}

	resendKey := strings.TrimSpace(os.Getenv(EnvResendKey))
	if resendKey != "" {
		return &resendSender{
			apiKey: resendKey,
			from:   from,
			client: &http.Client{Timeout: 15 * time.Second},
		}
	}

	host := strings.TrimSpace(os.Getenv(EnvHost))
	if host != "" {
		if !strings.Contains(host, ":") {
			host += ":587"
		}
		return smtpSender{
			addr:     host,
			from:     from,
			user:     os.Getenv(EnvUser),
			password: os.Getenv(EnvPassword),
		}
	}

	return logSender{log: log}
}

// resendSender sends emails via Resend REST API (https://api.resend.com/emails).
type resendSender struct {
	apiKey string
	from   string
	client *http.Client
}

func (r *resendSender) Transport() string { return "resend" }

func (r *resendSender) Send(ctx context.Context, to, subject, body string) error {
	return r.SendHTML(ctx, to, subject, body, "")
}

func (r *resendSender) SendHTML(ctx context.Context, to, subject, body, html string) error {
	payload := map[string]any{
		"from":    r.from,
		"to":      []string{to},
		"subject": subject,
		"text":    body,
	}
	if html != "" {
		payload["html"] = html
	}

	jsonBytes, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.resend.com/emails", bytes.NewReader(jsonBytes))
	if err != nil {
		return err
	}

	req.Header.Set("Authorization", "Bearer "+r.apiKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := r.client.Do(req)
	if err != nil {
		return fmt.Errorf("resend request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		resBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return fmt.Errorf("resend error (%d): %s", resp.StatusCode, strings.TrimSpace(string(resBody)))
	}

	return nil
}

type smtpSender struct{ addr, from, user, password string }

func (s smtpSender) Transport() string { return "smtp" }

func (s smtpSender) Send(ctx context.Context, to, subject, body string) error {
	return s.SendHTML(ctx, to, subject, body, "")
}

func (s smtpSender) SendHTML(ctx context.Context, to, subject, body, html string) error {
	if strings.ContainsAny(to, "\r\n") || strings.ContainsAny(subject, "\r\n") {
		return fmt.Errorf("invalid mail header")
	}
	host, _, err := net.SplitHostPort(s.addr)
	if err != nil {
		return err
	}
	var auth smtp.Auth
	if s.user != "" {
		auth = smtp.PlainAuth("", s.user, s.password, host)
	}
	head := []string{
		"From: " + s.from,
		"To: " + to,
		"Subject: " + mime.QEncoding.Encode("utf-8", subject),
		"Date: " + time.Now().UTC().Format(time.RFC1123Z),
		"MIME-Version: 1.0",
	}
	var msg string
	if html == "" {
		msg = strings.Join(append(head, "Content-Type: text/plain; charset=UTF-8", "", body), "\r\n")
	} else {
		const boundary = "aseman-alt-boundary"
		msg = strings.Join(append(head,
			"Content-Type: multipart/alternative; boundary="+boundary, "",
			"--"+boundary, "Content-Type: text/plain; charset=UTF-8", "", body,
			"--"+boundary, "Content-Type: text/html; charset=UTF-8", "", html,
			"--"+boundary+"--", ""), "\r\n")
	}
	done := make(chan error, 1)
	go func() { done <- smtp.SendMail(s.addr, auth, s.from, []string{to}, []byte(msg)) }()
	select {
	case err := <-done:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

type logSender struct{ log *logger.Logger }

func (s logSender) Transport() string { return "log" }

func (s logSender) Send(_ context.Context, to, subject, body string) error {
	if s.log != nil {
		s.log.Warn("email service not configured; email written to node log", "to", to, "subject", subject, "body", body)
	}
	return nil
}
