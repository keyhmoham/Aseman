package deepagents

import (
	"context"
	"strings"
	"testing"
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
	data, err := a.followStream(&session{base: context.Background()}, "tradera", strings.NewReader(body))
	if err != nil || string(data) != body {
		t.Fatalf("the runtime must get the stream unchanged: %v", err)
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
	if _, err := a.followStream(&session{base: context.Background()}, "tradera", strings.NewReader(body)); err != nil {
		t.Fatal(err)
	}
	if len(drafts) == 0 || drafts[len(drafts)-1] != "" {
		t.Fatalf("a tool step must end with no draft: %q", drafts)
	}
}
