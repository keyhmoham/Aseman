package bots

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/aseman/aseman/pkg/errs"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
)

// A chat answer is streamed: the text reaches the person as the model writes it. Only the
// start can be retried or handed to another model; once words have been shown, a failure
// ends the answer with what was written (the person has already read it).

// chatLimits are how long a model may stay silent before it is given up on.
type chatLimits struct {
	// firstToken is the wait for the model to begin (headers and the first sign of life),
	// including any thinking it does first.
	firstToken time.Duration
	// idle is the longest pause between two events once it has begun.
	idle time.Duration
}

var defaultChatLimits = chatLimits{firstToken: 45 * time.Second, idle: 30 * time.Second}

// chatResult is one finished (or cut-off) answer.
type chatResult struct {
	Text string
	// In and Out are the tokens the provider reported for the attempt that answered (0 when it reported none).
	In, Out int64
	// Model is the model that answered, and Attempts how many were started (1: the first answered).
	Model    string
	Attempts int
}

// retryableStatus: the model could answer if asked again, or another could. A 400 is the
// request's own fault, and goes to nobody else.
func chatFailoverStatus(status int) bool {
	switch status {
	case 401, 402, 403, 404, 408, 429:
		return true
	}
	return status >= 500
}

// chatRetrySame: asking the same model again can work (not a rejected key or a missing model).
func chatRetrySame(status int) bool {
	switch status {
	case 401, 402, 403, 404:
		return false
	}
	return true
}

// chatAttemptError is why an attempt failed, and whether anything had been shown by then.
type chatAttemptError struct {
	err    error
	status int  // HTTP status, 0 when the failure was not one
	shown  bool // words had reached the person
}

type chatEvent struct {
	text    string // visible text to add
	alive   bool   // any sign of life (thinking counts)
	in, out int64
	done    bool
	err     error
	status  int
}

// streamChat asks the models in order until one answers: each of `models` once, the first
// again before the next when its failure could pass (a stall, a dropped stream, a busy
// provider). `onText` gets the whole answer so far as it grows. The body is sent with
// stream:true. An error comes back with the text written so far, which may be none.
func streamChat(ctx context.Context, client *http.Client, models []vmm.ProviderConfig, body map[string]any, limits chatLimits, onText func(string)) (chatResult, error) {
	if len(models) == 0 {
		return chatResult{}, errs.New(errs.CodeUnavailable, "no model is available")
	}
	// The first model gets a second try before any other is asked.
	order := append([]vmm.ProviderConfig{models[0]}, models...)
	sent := make(map[string]any, len(body)+2)
	for k, v := range body {
		sent[k] = v
	}
	sent["stream"] = true
	sent["stream_options"] = map[string]any{"include_usage": true}

	var last chatAttemptError
	attempts := 0
	for i, provider := range order {
		if i == 1 && !chatRetrySame(last.status) {
			continue // a rejected key will not change its answer
		}
		attempts++
		text, in, out, fail := streamOnce(ctx, client, provider, sent, limits, onText)
		if fail == nil {
			return chatResult{Text: text, In: in, Out: out, Model: provider.Model, Attempts: attempts}, nil
		}
		last = *fail
		if ctx.Err() != nil {
			return chatResult{Text: text, Model: provider.Model, Attempts: attempts}, ctx.Err()
		}
		if fail.shown {
			// Words were shown: keep them, and say the answer ended early.
			return chatResult{Text: text, Model: provider.Model, Attempts: attempts}, fail.err
		}
		if fail.status != 0 && !chatFailoverStatus(fail.status) {
			return chatResult{Model: provider.Model, Attempts: attempts}, fail.err
		}
	}
	return chatResult{Attempts: attempts}, last.err
}

// streamOnce is one request to one model.
func streamOnce(ctx context.Context, client *http.Client, provider vmm.ProviderConfig, body map[string]any, limits chatLimits, onText func(string)) (text string, in, out int64, fail *chatAttemptError) {
	reqCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	req, err := vmm.ChatRequest(reqCtx, provider, "/chat/completions", body)
	if err != nil {
		return "", 0, 0, &chatAttemptError{err: err}
	}
	req.Header.Set("Accept", "text/event-stream")

	events := make(chan chatEvent, 16)
	go readChatStream(reqCtx, client, req, events)

	var answer strings.Builder
	wait := limits.firstToken
	timer := time.NewTimer(wait)
	defer timer.Stop()
	for {
		select {
		case ev := <-events:
			if ev.err != nil {
				return answer.String(), 0, 0, &chatAttemptError{err: ev.err, status: ev.status, shown: answer.Len() > 0}
			}
			if ev.in > 0 || ev.out > 0 {
				in, out = ev.in, ev.out
			}
			if ev.text != "" {
				answer.WriteString(ev.text)
				if onText != nil {
					onText(answer.String())
				}
			}
			if ev.done {
				return answer.String(), in, out, nil
			}
			if ev.alive || ev.text != "" {
				wait = limits.idle
			}
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(wait)
		case <-timer.C:
			return answer.String(), 0, 0, &chatAttemptError{err: errs.New(errs.CodeUnavailable, fmt.Sprintf("the model did not answer within %s", wait)), shown: answer.Len() > 0}
		case <-ctx.Done():
			return answer.String(), 0, 0, &chatAttemptError{err: ctx.Err(), shown: answer.Len() > 0}
		}
	}
}

// readChatStream sends the request and turns its event stream into events; the last is done or an error.
func readChatStream(ctx context.Context, client *http.Client, req *http.Request, out chan<- chatEvent) {
	// A send gives up when the caller has moved on, so this goroutine never outlives its attempt.
	events := sender{ctx: ctx, ch: out}
	resp, err := client.Do(req)
	if err != nil {
		events.send(chatEvent{err: errs.Wrap(errs.CodeUnavailable, err, "the model could not be reached")})
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		detail, _ := io.ReadAll(io.LimitReader(resp.Body, 400))
		events.send(chatEvent{status: resp.StatusCode, err: errs.New(errs.CodeUnavailable, fmt.Sprintf("the model refused the request (%d) %s", resp.StatusCode, strings.TrimSpace(string(detail))))})
		return
	}
	events.send(chatEvent{alive: true}) // the headers: it is answering
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 4<<20)
	for scanner.Scan() {
		payload, ok := strings.CutPrefix(strings.TrimSpace(scanner.Text()), "data:")
		if !ok {
			continue
		}
		payload = strings.TrimSpace(payload)
		if payload == "[DONE]" {
			break
		}
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content          any `json:"content"`
					ReasoningContent any `json:"reasoning_content"`
				} `json:"delta"`
			} `json:"choices"`
			Usage *struct {
				PromptTokens     int64 `json:"prompt_tokens"`
				CompletionTokens int64 `json:"completion_tokens"`
			} `json:"usage"`
			Error *struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal([]byte(payload), &chunk) != nil {
			continue
		}
		if chunk.Error != nil && chunk.Error.Message != "" {
			events.send(chatEvent{err: errs.New(errs.CodeUnavailable, "the model failed: "+chunk.Error.Message)})
			return
		}
		ev := chatEvent{alive: true}
		for _, c := range chunk.Choices {
			ev.text += contentText(c.Delta.Content)
		}
		if chunk.Usage != nil {
			ev.in, ev.out = chunk.Usage.PromptTokens, chunk.Usage.CompletionTokens
		}
		events.send(ev)
	}
	if err := scanner.Err(); err != nil {
		events.send(chatEvent{err: errs.Wrap(errs.CodeUnavailable, err, "the model's answer was cut short")})
		return
	}
	events.send(chatEvent{done: true})
}

// sender sends events unless its attempt has been abandoned.
type sender struct {
	ctx context.Context
	ch  chan<- chatEvent
}

func (s sender) send(ev chatEvent) {
	select {
	case s.ch <- ev:
	case <-s.ctx.Done():
	}
}
