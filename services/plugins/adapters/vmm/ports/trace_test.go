package vmm

import (
	"context"
	"testing"
	"time"
)

func TestTraceRecordsPhasesAndIsInertWithoutTracer(t *testing.T) {
	Trace(context.Background(), "x", "")() // no tracer: nothing happens

	ctx, tr := WithTracer(context.Background())
	end := Trace(ctx, "sandbox.start", "wake")
	time.Sleep(5 * time.Millisecond)
	end()
	TraceFrom(ctx, "llm.call", "m", time.Now().Add(-20*time.Millisecond))

	spans := tr.Spans()
	if len(spans) != 2 || spans[0].Name != "sandbox.start" || spans[0].Ms < 5 || spans[1].Ms < 20 {
		t.Fatalf("spans = %+v", spans)
	}
}

func TestTracerIsBounded(t *testing.T) {
	_, tr := WithTracer(context.Background())
	for i := 0; i < 1000; i++ {
		tr.Add("n", "", time.Now(), 0)
	}
	if got := len(tr.Spans()); got != 400 {
		t.Fatalf("kept %d spans", got)
	}
}
