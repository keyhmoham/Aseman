package bot

import (
	"encoding/json"

	"github.com/aseman/aseman/pkg/errs"
)

func unmarshalJSON(s string, out any) error {
	if err := json.Unmarshal([]byte(s), out); err != nil {
		return errs.Wrap(errs.CodeInternal, err, "invalid json column")
	}
	return nil
}
