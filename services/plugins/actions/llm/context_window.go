package llm

import (
	"sort"
	"strings"

	llmprovider "github.com/tradera/tradera/plugins/actions/llm/models"
)

// knownWindows are the published input windows (tokens) of common model
// families, by model id prefix; the longest matching prefix wins, so a
// family entry covers its newer versions (gemini-3 covers gemini-3.1-pro,
// gemini-3.5-flash, …) and a narrower entry overrides it.
//
// Agents summarize their history at 48k tokens or less whatever the window,
// so a window only changes anything when it is small: an entry here errs low
// rather than high, and a family whose sizes vary keeps its smallest.
var knownWindows = map[string]int{
	// OpenAI
	"gpt-3.5":       16_385,
	"gpt-4":         8_192,
	"gpt-4-32k":     32_768,
	"gpt-4-turbo":   128_000,
	"gpt-4-1106":    128_000,
	"gpt-4-0125":    128_000,
	"gpt-4o":        128_000,
	"chatgpt-4o":    128_000,
	"gpt-4.1":       1_047_576,
	"gpt-4.5":       128_000,
	"gpt-5":         272_000,
	"gpt-6":         272_000,
	"gpt-oss":       131_072,
	"o1":            200_000,
	"o1-mini":       128_000,
	"o1-preview":    128_000,
	"o3":            200_000,
	"o4":            200_000,
	"codex":         200_000,
	"computer-use":  8_192,
	"gpt-realtime":  32_000,
	"gpt-audio":     128_000,
	"gpt-image":     32_000,
	"text-davinci":  4_096,
	"davinci":       16_384,
	"babbage":       16_384,
	"ft:gpt-3.5":    16_385,
	"ft:gpt-4o":     128_000,
	"ft:gpt-4.1":    1_047_576,
	"omni-moderate": 32_768,

	// Google (AI Studio and Vertex AI)
	"gemini-1.0":                     32_760,
	"gemini-pro":                     32_760,
	"gemini-pro-vision":              12_288,
	"gemini-1.5":                     1_048_576,
	"gemini-2":                       1_048_576,
	"gemini-2.0-flash-preview-image": 32_768,
	"gemini-2.0-flash-exp-image":     32_768,
	"gemini-2.5-flash-image":         32_768,
	"gemini-2.5-flash-preview-tts":   8_192,
	"gemini-2.5-pro-preview-tts":     8_192,
	"gemini-2.5-flash-native-audio":  128_000,
	"gemini-live":                    128_000,
	"gemini-3":                       1_048_576,
	"gemini-3-pro-image":             65_536,
	"gemini-3.1-flash-image":         65_536,
	"gemini-4":                       1_048_576,
	"gemini-flash":                   1_048_576, // gemini-flash-latest, gemini-flash-lite-latest
	"gemini-pro-latest":              1_048_576,
	"gemini-exp":                     1_048_576,
	"gemini-embedding":               2_048,
	"gemma-2":                        8_192,
	"gemma-3":                        128_000,
	"gemma-3-1b":                     32_768,
	"gemma-3n":                       32_768,
	"gemma-4":                        128_000,
	"learnlm":                        32_768,
	"medgemma":                       128_000,
	"text-bison":                     8_192,
	"chat-bison":                     8_192,
	"codechat-bison":                 6_144,

	// Anthropic (direct, Vertex AI "claude-…@date", Bedrock "anthropic.claude-…")
	"claude":         200_000,
	"claude-2":       100_000,
	"claude-instant": 100_000,

	// xAI
	"grok-beta":     131_072,
	"grok-vision":   8_192,
	"grok-2":        131_072,
	"grok-2-vision": 32_768,
	"grok-3":        131_072,
	"grok-4":        256_000,
	"grok-code":     256_000,
	"grok-5":        256_000,

	// DeepSeek
	"deepseek":          64_000,
	"deepseek-chat":     128_000,
	"deepseek-coder":    128_000,
	"deepseek-r1":       128_000,
	"deepseek-v3":       128_000,
	"deepseek-v4":       128_000,
	"deepseek-reasoner": 128_000,

	// Meta
	"llama-2":     4_096,
	"llama2":      4_096,
	"llama-3":     8_192,
	"llama3":      8_192,
	"llama-3.1":   128_000,
	"llama3.1":    128_000,
	"llama-3.2":   128_000,
	"llama3.2":    128_000,
	"llama-3.3":   128_000,
	"llama3.3":    128_000,
	"llama-4":     128_000,
	"llama4":      128_000,
	"llama-guard": 8_192,

	// Mistral
	"mistral":           32_000,
	"mistral-large":     128_000,
	"mistral-medium":    128_000,
	"mistral-small":     32_000,
	"mistral-small-3":   128_000,
	"mistral-saba":      32_000,
	"mistral-nemo":      128_000,
	"open-mistral-nemo": 128_000,
	"open-mistral":      32_000,
	"open-mixtral":      32_000,
	"mixtral":           32_000,
	"ministral":         128_000,
	"magistral":         40_000,
	"codestral":         256_000,
	"devstral":          128_000,
	"pixtral":           128_000,

	// Alibaba
	"qwen":                 32_768,
	"qwen-plus":            131_072,
	"qwen-turbo":           131_072,
	"qwen-long":            1_000_000,
	"qwen2.5-1m":           1_000_000,
	"qwen3":                32_768,
	"qwen3-coder":          262_144,
	"qwen3-max":            262_144,
	"qwen3-235b-a22b-2507": 262_144,
	"qwen3-30b-a3b-2507":   262_144,
	"qwen3-next":           262_144,
	"qwen3.5":              262_144,
	"qwq":                  131_072,

	// Moonshot, Zhipu, MiniMax and others
	"kimi":             128_000,
	"kimi-k2":          128_000,
	"kimi-k2-0905":     256_000,
	"kimi-k2-thinking": 256_000,
	"kimi-k2.5":        256_000,
	"kimi-k2.6":        256_000,
	"moonshot":         8_192,
	"moonshot-v1-32k":  32_768,
	"moonshot-v1-128k": 128_000,
	"glm-4":            128_000,
	"glm-4v":           8_192,
	"glm-4.5":          128_000,
	"glm-4.6":          200_000,
	"glm-5":            128_000,
	"minimax":          128_000,
	"abab":             128_000,
	"command":          4_096,
	"command-r":        128_000,
	"command-a":        256_000,
	"phi-3":            4_096,
	"phi-3.5":          128_000,
	"phi-4":            16_384,
	"nova-micro":       128_000,
	"nova-lite":        300_000,
	"nova-pro":         300_000,
	"nova-premier":     1_000_000,
	"nova-2":           300_000,
	"jamba":            256_000,
	"sonar":            127_000,
	"sonar-pro":        200_000,
	"nemotron":         128_000,
	"yi-":              16_384,
	"ernie":            8_192,
	"hunyuan":          32_000,
	"doubao":           32_000,
}

// knownPrefixes are knownWindows' keys, longest first.
var knownPrefixes = func() []string {
	out := make([]string, 0, len(knownWindows))
	for k := range knownWindows {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool {
		if len(out[i]) != len(out[j]) {
			return len(out[i]) > len(out[j])
		}
		return out[i] < out[j]
	})
	return out
}()

// ContextWindow is a model's input window in tokens: what the admin set on
// the model, else the published window of its family, else 0 (unknown).
func ContextWindow(m llmprovider.Model) int {
	if m.ContextWindow > 0 {
		return m.ContextWindow
	}
	id := strings.ToLower(strings.TrimSpace(m.ID))
	// google/gemini-2.5-pro, publishers/google/models/gemini-3-flash, meta-llama/…
	if i := strings.LastIndex(id, "/"); i >= 0 {
		id = id[i+1:]
	}
	if w := knownWindow(id); w > 0 {
		return w
	}
	// Bedrock and similar: us.anthropic.claude-…, amazon.nova-pro-v1:0, meta.llama3-…
	for i := strings.Index(id, "."); i >= 0; {
		if w := knownWindow(id[i+1:]); w > 0 {
			return w
		}
		next := strings.Index(id[i+1:], ".")
		if next < 0 {
			break
		}
		i += next + 1
	}
	return 0
}

func knownWindow(id string) int {
	for _, prefix := range knownPrefixes {
		if strings.HasPrefix(id, prefix) {
			return knownWindows[prefix]
		}
	}
	return 0
}
