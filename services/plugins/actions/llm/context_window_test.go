package llm

import (
	"testing"

	llmprovider "github.com/aseman/aseman/plugins/actions/llm/models"
)

func TestContextWindow(t *testing.T) {
	cases := map[string]int{
		"gpt-4o-mini":                                  128_000,
		"gpt-4.1-mini":                                 1_047_576,
		"google/gemini-2.5-pro":                        1_048_576,
		"claude-sonnet-4-5":                            200_000,
		"some-local-model":                             0,
		"gemini-3.1-pro-preview":                       1_048_576,
		"gemini-3.8-flash":                             1_048_576,
		"gemini-3-pro-image-preview":                   65_536,
		"gemini-2.5-flash-image":                       32_768,
		"gemini-flash-latest":                          1_048_576,
		"publishers/google/models/gemini-3-flash":      1_048_576,
		"claude-opus-4-1@20250805":                     200_000,
		"us.anthropic.claude-sonnet-4-5-20250929-v1:0": 200_000,
		"amazon.nova-pro-v1:0":                         300_000,
		"meta.llama3-70b-instruct-v1:0":                8_192,
		"meta-llama/llama-3.3-70b-instruct":            128_000,
		"llama3-70b-8192":                              8_192,
		"deepseek/deepseek-chat:free":                  128_000,
		"qwen3-coder-plus":                             262_144,
		"qwen3-32b":                                    32_768,
		"moonshot-v1-8k":                               8_192,
		"o1-mini":                                      128_000,
		"o3-mini":                                      200_000,
		"gpt-4":                                        8_192,
		"gpt-4-turbo-2024-04-09":                       128_000,
		"gpt-5.5":                                      272_000,
	}
	for id, want := range cases {
		if got := ContextWindow(llmprovider.Model{ID: id}); got != want {
			t.Errorf("ContextWindow(%q) = %d, want %d", id, got, want)
		}
	}
	if got := ContextWindow(llmprovider.Model{ID: "gpt-4o", ContextWindow: 64_000}); got != 64_000 {
		t.Errorf("the admin's window should win, got %d", got)
	}
}

func TestVercelGatewayModelIDsResolveWindows(t *testing.T) {
	p, ok := llmprovider.PresetFor(llmprovider.KindVercel)
	if !ok || p.BaseURL != "https://ai-gateway.vercel.sh/v1" {
		t.Fatalf("vercel preset = %+v, ok=%v", p, ok)
	}
	// The gateway names models "<creator>/<model>".
	if w := ContextWindow(llmprovider.Model{ID: "openai/gpt-4.1"}); w != 1_047_576 {
		t.Errorf("openai/gpt-4.1 window = %d", w)
	}
}
