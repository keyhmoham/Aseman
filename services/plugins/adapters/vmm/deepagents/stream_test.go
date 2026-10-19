package deepagents

import (
	"context"
	"io"
	"strings"
	"testing"
	"time"
)

func sse(lines ...string) string {
	var b strings.Builder
	for _, l := range lines {
		b.WriteString("data: " + l + "\n\n")
	}
	b.WriteString("data: [DONE]\n\n")
	return b.String()
}

func TestFollowStreamPublishesTheAnswerAndReturnsItWhole(t *testing.T) {
	var drafts []string
	a := &Adapter{draftFn: func(_, _, text string) { drafts = append(drafts, text) }}
	body := sse(`{"choices":[{"delta":{"content":"Light "}}]}`, `{"choices":[{"delta":{"content":"attracts bugs."}}]}`,
		`{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":4}}`)
	data, stats, err := a.followStream(context.Background(), &session{base: context.Background()}, "tradera",
		io.NopCloser(strings.NewReader(body)), true, time.Second, time.Second)
	if err != nil || string(data) != body {
		t.Fatalf("the runtime must get the stream unchanged: %v", err)
	}
	if !stats.done {
		t.Fatal("the [DONE] event was not recognized")
	}
	if len(drafts) == 0 || drafts[len(drafts)-1] != "Light attracts bugs." {
		t.Fatalf("drafts = %q", drafts)
	}
	if in, out := parseUsage(data, true); in != 10 || out != 4 {
		t.Fatalf("usage lost: %d/%d", in, out)
	}
}

func TestFollowStreamWithdrawsAStepThatCallsATool(t *testing.T) {
	var drafts []string
	a := &Adapter{draftFn: func(_, _, text string) { drafts = append(drafts, text) }}
	body := sse(`{"choices":[{"delta":{"content":"Let me check."}}]}`,
		`{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"execute"}}]}}]}`,
		`{"choices":[{"delta":{"content":"ignored"}}]}`)
	if _, _, err := a.followStream(context.Background(), &session{base: context.Background()}, "tradera",
		io.NopCloser(strings.NewReader(body)), true, time.Second, time.Second); err != nil {
		t.Fatal(err)
	}
	if len(drafts) == 0 || drafts[len(drafts)-1] != "" {
		t.Fatalf("a tool step must end with no draft: %q", drafts)
	}
}

func TestFollowStreamReturnsAtDoneWithoutWaitingForHTTPToClose(t *testing.T) {
	reader, writer := io.Pipe()
	t.Cleanup(func() { _ = writer.Close() })
	go func() {
		_, _ = io.WriteString(writer, sse(`{"choices":[{"delta":{"content":"finished"}}]}`))
		// Deliberately leave the pipe open: this reproduces an intermediary that
		// delivered the terminal SSE event but retained its HTTP connection.
	}()
	result := make(chan error, 1)
	go func() {
		_, stats, err := (&Adapter{}).followStream(context.Background(), &session{base: context.Background()},
			"tradera", reader, false, time.Second, time.Second)
		if err == nil && !stats.done {
			err = io.ErrUnexpectedEOF
		}
		result <- err
	}()
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(250 * time.Millisecond):
		t.Fatal("followStream waited for HTTP EOF after [DONE]")
	}
}

func TestFollowStreamFailsWhenAnOpenStreamGoesIdle(t *testing.T) {
	reader, writer := io.Pipe()
	t.Cleanup(func() { _ = writer.Close() })
	go func() {
		_, _ = io.WriteString(writer, "data: {\"choices\":[{\"delta\":{\"content\":\"started\"}}]}\n\n")
	}()
	_, _, err := (&Adapter{}).followStream(context.Background(), &session{base: context.Background()},
		"tradera", reader, false, time.Second, 20*time.Millisecond)
	if !isStreamTimeout(err) {
		t.Fatalf("idle stream error = %v, want a stream timeout", err)
	}
}
