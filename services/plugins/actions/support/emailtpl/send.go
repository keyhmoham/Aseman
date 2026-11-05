package emailtpl

import (
	"context"

	"github.com/aseman/aseman/internal/plugins/api"
	"github.com/aseman/aseman/internal/plugins/bridge"
	"github.com/aseman/aseman/plugins/actions/support/mail"
)

// Send writes the email `key` with the wording the admin saved in settings
// (else the default) and delivers it. A node without the settings namespace
// sends the defaults.
func Send(ctx context.Context, k api.Kernel, sender mail.Sender, to, key string, vars map[string]string) error {
	def, ok := Find(key)
	if !ok {
		return nil
	}
	var saved map[string]Content
	_ = bridge.Invoke(ctx, k, "settings", "EmailTemplates", []any{ctx}, &saved)
	var content *Content
	if c, ok := saved[key]; ok {
		content = &c
	}
	r := Render(def, content, vars)
	return mail.Deliver(ctx, sender, to, r.Subject, r.Text, r.HTML)
}
