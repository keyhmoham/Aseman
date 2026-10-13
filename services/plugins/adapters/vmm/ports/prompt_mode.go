package vmm

import "strings"

// ParsePromptMode consumes leading chat modifiers only, never prose or paths.
// Modifiers may be combined; their restrictions only accumulate.
func ParsePromptMode(prompt string) (string, bool, bool) {
	remaining := strings.TrimSpace(prompt)
	noSandbox, noMemory := false, false
	for remaining != "" {
		word := strings.Fields(remaining)[0]
		switch word {
		case "/btw":
			noSandbox, noMemory = true, true
		case "/ask":
			noSandbox = true
		case "/fresh":
			noMemory = true
		default:
			return remaining, noSandbox, noMemory
		}
		remaining = strings.TrimSpace(remaining[len(word):])
	}
	return remaining, noSandbox, noMemory
}
