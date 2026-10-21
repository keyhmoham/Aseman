package spaces

import (
	"github.com/aseman/aseman/pkg/errs"
	vmm "github.com/aseman/aseman/plugins/adapters/vmm/ports"
	"strconv"
	"strings"
)

// Adapter exec results retain the stable exit=N header. Do not classify prose
// or missing headers as command failures; provider failures use typed errors.
func sandboxCommandError(result string) error {
	header, _, _ := strings.Cut(result, "\n")
	raw, ok := strings.CutPrefix(header, "exit=")
	if !ok {
		return nil
	}
	code, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil || code == 0 {
		return nil
	}
	return errs.New(vmm.CodeToolExecutionFailed, "sandbox command exited with status "+strconv.Itoa(code))
}
