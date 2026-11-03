package vmm

import (
	"context"
	"testing"
)

func TestTurnLLMRoundTrip(t *testing.T) {
	ctx := WithTurnLLM(context.Background(), TurnLLM{
		Token:   "tok",
		BaseURL: "http://aseman:8080/harness/v1/llm",
		Model:   "aseman/default",
	})
	got := TurnLLMFrom(ctx)
	if got.Token != "tok" || got.BaseURL == "" || got.Model != "aseman/default" {
		t.Fatalf("got %#v", got)
	}
	if TurnLLMFrom(context.Background()).Token != "" {
		t.Fatal("empty context should have no turn LLM")
	}
}
