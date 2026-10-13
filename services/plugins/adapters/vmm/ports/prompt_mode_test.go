package vmm

import "testing"

func TestParsePromptMode(t *testing.T) {
	for _, tc := range []struct {
		input, request      string
		noSandbox, noMemory bool
	}{
		{"/btw explain", "explain", true, true},
		{" /ask\nexplain", "explain", true, false},
		{"/fresh explain", "explain", false, true},
		{"/ask /fresh explain", "explain", true, true},
		{"/btw", "", true, true},
		{"/asker explain", "/asker explain", false, false},
		{"read /fresh/file", "read /fresh/file", false, false},
		{"explain /btw", "explain /btw", false, false},
	} {
		request, noSandbox, noMemory := ParsePromptMode(tc.input)
		if request != tc.request || noSandbox != tc.noSandbox || noMemory != tc.noMemory {
			t.Errorf("%q => %q, %v, %v", tc.input, request, noSandbox, noMemory)
		}
	}
}
