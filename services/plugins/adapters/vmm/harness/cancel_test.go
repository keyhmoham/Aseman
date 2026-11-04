package harness

import (
	"context"
	"testing"
	"time"
)

func TestAnInterruptedCallIsMetered(t *testing.T) {
	body := map[string]any{"messages": []any{map[string]any{"role": "user", "content": "write a long story"}}}
	// The provider's own report wins when it arrived before the cut.
	reported := []byte("data: {\"choices\":[{\"delta\":{\"content\":\"Once\"}}]}\n\ndata: {\"usage\":{\"prompt_tokens\":900,\"completion_tokens\":40}}\n\n")
	if in, out, est := partialUsage(body, reported, true); in != 900 || out != 40 || est {
		t.Fatalf("reported: %d %d %v", in, out, est)
	}
	// Else it is estimated: the input from the request, the output from what was streamed.
	cut := []byte("data: {\"choices\":[{\"delta\":{\"content\":\"Once upon a time, far away\"}}]}\n\n" +
		"data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"name\":\"write_file\",\"arguments\":\"{\\\"path\\\":\\\"a.md\\\"}\"}}]}}]}\n\n")
	in, out, est := partialUsage(body, cut, true)
	if !est || in != estimateInputTokens(body) || in < 10 || out < 8 {
		t.Fatalf("estimated: %d %d %v", in, out, est)
	}
	// Nothing streamed yet: the input alone.
	if in, out, _ := partialUsage(body, nil, true); in == 0 || out != 0 {
		t.Fatalf("nothing streamed: %d %d", in, out)
	}
}

func TestAStoppedTurnWaitsForItsCallsBeforeItIsCharged(t *testing.T) {
	s := &session{}
	done := s.begin()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	go func() {
		time.Sleep(80 * time.Millisecond)
		done()
	}()
	start := time.Now()
	s.settle(ctx)
	if s.inflight.Load() != 0 || time.Since(start) < 60*time.Millisecond {
		t.Fatalf("settle returned with %d in flight after %s", s.inflight.Load(), time.Since(start))
	}
	// A turn that ran to its end does not wait.
	s.begin()
	start = time.Now()
	s.settle(context.Background())
	if time.Since(start) > 20*time.Millisecond {
		t.Fatal("an unstopped turn waited")
	}
	// And a stuck call never holds a stopped turn longer than the bound.
	old := settleTimeout
	settleTimeout = 50 * time.Millisecond
	defer func() { settleTimeout = old }()
	start = time.Now()
	s.settle(ctx)
	if d := time.Since(start); d < 40*time.Millisecond || d > time.Second {
		t.Fatalf("bounded wait took %s", d)
	}
}
