package tools

// Frontends designed for one request: when an agent shows a result from a
// tool without a generative frontend of its own, the node designs an
// interface for that request, around the result it shows. Nothing of it is
// cached: the template belongs to the one desk window it was made for (the
// desk keeps it with the window), and another request gets its own.

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/tradera/tradera/internal/plugins/api"
	"github.com/tradera/tradera/internal/plugins/identity"
	"github.com/tradera/tradera/pkg/errs"
	"github.com/tradera/tradera/plugins/actions/tools/models"
)

// maxSample bounds the result sample the design is shown.
const maxSample = 4000

// windowTemplate reads a desk window's own template.
func windowTemplate(raw map[string]any) (*Template, error) {
	t, err := templateOf(raw)
	if err != nil {
		return nil, errs.InvalidArgument("the window's frontend is not a template")
	}
	if err := t.validate(nil); err != nil {
		return nil, err
	}
	return &t, nil
}

// requestSkill is what the design follows: the person's request, the result
// to show and its shape.
func requestSkill(request, microtool string, args map[string]any, sample string) string {
	var b strings.Builder
	b.WriteString("Design a card window for exactly this request, not a general interface for the tool:\n")
	b.WriteString(strings.TrimSpace(request) + "\n\n")
	if microtool != "" {
		rawArgs, _ := json.Marshal(args)
		b.WriteString("It shows the result of the microtool " + microtool + " called with " + string(rawArgs) + ". ")
		b.WriteString("Bind that result with a data binding to " + microtool + " with exactly these arguments.\n")
	}
	if sample != "" {
		b.WriteString("The result looks like this (a sample, possibly cut short):\n" + sample + "\n")
	}
	b.WriteString(`Show what the request is about first and most prominently, the way the data deserves (Stat tiles for the figures asked for, a Chart for series, a Table for records, KeyValue for one record); leave out what the request does not need. Add controls only where they serve the request (refining it, e.g. another city or period), mapped to the microtools by actions. Keep it to one compact window. Use Image, Video or AudioPlayer only for media the result actually carries (bind their url to it, e.g. a url, a file path or an item of "media"); never invent a url or show an empty picture, and when the result holds no media show what it does hold.`)
	return b.String()
}

// GenerateWindowFrontend designs a frontend for one request to a tool and
// returns its template (JSON). [payer] is the account asking (billed for the
// model); the result sample is fetched as them, in [space] and [room].
func (s *Service) GenerateWindowFrontend(ctx context.Context, payer, space, room, botID, request, microtool string, args map[string]any) (string, error) {
	payerID, err := identity.Parse(payer)
	if err != nil {
		return "", errs.InvalidArgument("invalid payer")
	}
	var tool models.Tool
	if err := s.R.GetString(ctx, "tool_registry", botID, &tool); err != nil {
		return "", errs.NotFound("tool " + botID)
	}
	c := caller{Caller: api.Caller{ID: payerID}, Space: space, Room: room}
	commands, err := s.CommandsFor(ctx, tool.BotID, payer, space)
	if err != nil || len(commands) == 0 {
		commands = tool.Commands
	}
	sample := ""
	if microtool != "" {
		if v, err := s.call(ctx, c, tool.BotID, microtool, args); err == nil {
			raw, _ := json.MarshalIndent(v, "", " ")
			sample = string(raw)
			if len(sample) > maxSample {
				sample = sample[:maxSample] + "\n…"
			}
		}
	}
	t, _, err := s.generate(ctx, c, &tool, requestSkill(request, microtool, args, sample), commands)
	if err != nil {
		return "", err
	}
	raw, _ := json.Marshal(t)
	return string(raw), nil
}
